#lang racket/base

#|
   Copyright 2016-2017 Leif Andersen

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
|#

(provide (all-defined-out))
(require racket/match
         ffi/unsafe
         racket/set
         "init-mlt.rkt"
         "packetqueue.rkt"
         "ffmpeg.rkt"
         "threading.rkt")

(struct stream-bundle (streams
                       avformat-context
                       options-dict
                       file)
  #:mutable)
(define (mk-stream-bundle #:streams [s '()]
                          #:avformat-context [ctx #f]
                          #:options [o #f]
                          #:file [f #f])
  (stream-bundle s ctx o f))

(struct codec-obj (orig-codec-context
                   type
                   index
                   id
                   codec
                   codec-context
                   stream
                   next-pts
                   callback-data)
  #:mutable)
(define (mk-codec-obj #:orig-codec-context [occ #f]
                      #:type [t #f]
                      #:index [i #f]
                      #:id [id #f]
                      #:codec [codec #f]
                      #:codec-context [codec-context #f]
                      #:stream [s #f]
                      #:next-pts [n #f]
                      #:callback-data [cd #f])
  (codec-obj occ t i id codec codec-context s n cd))

(define (empty-proc mode obj packet)
  (when packet
    (av-packet-unref packet)))

;; (U av-dictionary Hash #f) -> av-dictionary
(define (convert-dict dict)
  (cond
    [(hash? dict)
     (define ret #f)
     (for ([(k v) (in-hash dict)])
       (set! ret (av-dict-set ret k v 0)))
     ret]
    [else dict]))

(define (file->stream-bundle file)
  (define avformat (avformat-open-input file #f #f))
  (avformat-find-stream-info avformat #f)
  (define raw-strs (avformat-context-streams avformat))
  (mk-stream-bundle #:streams raw-strs
                    #:avformat-context avformat))

;; Callback ops:
;;   'init
;;   'loop
;;   'close
(define (demux-stream bundle
                      #:video-callback [video-callback empty-proc]
                      #:audio-callback [audio-callback empty-proc]
                      #:subtitle-callback [subtitle-callback empty-proc]
                      #:data-callback [data-callback empty-proc]
                      #:attachment-callback [attachment-callback empty-proc]
                      #:by-index-callback [by-index-callback #f])
  ;; Open file
  (define avformat (stream-bundle-avformat-context bundle))
  (define raw-strs (stream-bundle-streams bundle))
  ;(av-dump-format avformat 0 testfile 0)
  ;; Init Streams
  (define stream-table (make-hash))
  (define streams
    (for/vector ([i raw-strs]
                 [i* (in-naturals)])
      (define old-codec-ctx (avstream-codec i))
      (define codec-name (avcodec-context-codec-type* old-codec-ctx))
      (define codec-id (avcodec-context-codec-id old-codec-ctx))
      (define codec (avcodec-find-decoder codec-id))
      (define codec-ctx (avcodec-copy-context codec old-codec-ctx))
      (avcodec-open2 codec-ctx codec #f)
      (define obj (codec-obj old-codec-ctx codec-name i* codec-id codec codec-ctx #f 0 #f))
      (when (and (not by-index-callback) (hash-ref stream-table codec-name #f))
        (error 'decoder-stream "Stream type ~a already present" codec-name))
      (hash-set! stream-table codec-name obj)
      (when by-index-callback
        (by-index-callback 'init obj #f))
      obj))
  (unless by-index-callback
    (for ([(k v) (in-hash stream-table)])
      (match k
        ['video (video-callback 'init v #f)]
        ['audio (audio-callback 'init v #f)]
        ['subtitle (subtitle-callback 'init v #f)]
        ['data (data-callback 'init v #f)]
        ['attachment (attachment-callback 'init v #f)])))
  ;; Main Loop
  (let loop ()
    (define packet (av-read-frame avformat))
    (when packet
      (define index (avpacket-stream-index packet))
      (define obj (vector-ref streams index))
      (cond [by-index-callback (by-index-callback 'loop obj packet)]
            [else
             (define type (codec-obj-type obj))
             (cond [(eq? obj (hash-ref stream-table type))
                    (match type
                      ['video (video-callback 'loop obj packet)]
                      ['audio (audio-callback 'loop obj packet)]
                      ['subtitle (subtitle-callback 'loop obj packet)]
                      ['data (data-callback 'loop obj packet)]
                      ['attachment (attachment-callback 'loop obj packet)]
                      [_ (av-packet-unref packet)])]
                   [else (av-packet-unref packet)])])
      (loop)))
  ;; Close Down
  (unless by-index-callback
    (for ([(k v) (in-hash stream-table)])
      (match k
        ['video (video-callback 'close v #f)]
        ['audio (audio-callback 'close v #f)]
        ['subtitle (subtitle-callback 'close v #f)]
        ['data (data-callback 'close v #f)]
        ['attachment (attachment-callback 'close v #f)])))
  (for ([i (in-vector streams)])
    (match i
      [(struct* codec-obj
                ([orig-codec-context orig-codec-context]
                 [codec-context codec-context]
                 [index index]))
       (when by-index-callback
         (by-index-callback 'close i #f))
       (avcodec-close orig-codec-context) ;; XXX, should probably nix, deprecated
       (avcodec-close codec-context)]))
  (avformat-close-input avformat))

(define (bundle-for-file file bundle
                         #:options-dict [options-dict #f])
  (define streams
    (for/vector ([i (stream-bundle-streams bundle)])
      (match i
        [(struct* codec-obj ([type t]
                             [id i]))
         (mk-codec-obj #:type t
                       #:id i)]
        [x (mk-codec-obj #:type x)])))
  (define output-context
    (avformat-alloc-output-context2 #f #f file))
  (mk-stream-bundle #:avformat-context output-context
                    #:options-dict options-dict
                    #:file file))

;; Callback ops:
;;   'init
;;   'open
;;   'write
;;   'close
(define (mux-stream bundle
                    #:video-callback [video-callback empty-proc]
                    #:audio-callback [audio-callback empty-proc]
                    #:subtitle-callback [subtitle-callback empty-proc]
                    #:data-callback [data-callback empty-proc]
                    #:attachment-callback [attachment-callback empty-proc]
                    #:by-index-callback [by-index-callback #f])
  ;; Initial Setup
  (define output-context
    (stream-bundle-avformat-context bundle))
  (define options (convert-dict (stream-bundle-options-dict bundle)))
  (define file (stream-bundle-file bundle))
  (define format (avformat-context-oformat output-context))
  (define video-codec (av-output-format-video-codec format))
  (define audio-codec (av-output-format-audio-codec format))
  (define subtitle-codec (av-output-format-subtitle-codec format))
  ;; Get streams
  (define stream-table (make-hash))
  (define streams (stream-bundle-streams bundle))
  ;; Get codec and other attributes of decoded video
  (for ([i (in-vector streams)])
    (match i
      [(struct* codec-obj
                ([id id]
                 [type type]))
       (define type-codec-id
         (match type
           ['video video-codec]
           ['audio audio-codec]
           ['subtitle subtitle-codec]
           [else #f]))
       (define codec-id (or id type-codec-id))
       (define codec (avcodec-find-encoder codec-id))
       (set-codec-obj-codec! i codec)
       (define str (avformat-new-stream output-context #f))
       (set-codec-obj-stream! i str)
       (set-codec-obj-id! i codec-id)
       (set-avstream-id! str (sub1 (avformat-context-nb-streams output-context)))
       (define ctx (avcodec-alloc-context3 codec))
       (set-codec-obj-codec-context! i ctx)
       (match type
         ['video (video-callback 'init i)]
         ['audio (audio-callback 'init i)]
         ['subtitle (subtitle-callback 'init i)]
         [else (void)])
       (when (set-member? (avformat-context-flags output-context) 'globalheader)
         (set-add! (avcodec-context-flags ctx) 'global-heade))]))
  ;; Open Streams
  (for ([i (in-vector streams)])
    (match i
      [(struct* codec-obj
                ([type type]
                 [codec codec]
                 [codec-context ctx]
                 [stream stream]))
       (define str-opt (av-dict-copy options #f))
       (avcodec-open2 ctx codec str-opt)
       (av-dict-free str-opt)
       (avcodec-parameters-from-context (avstream-codecpar stream) ctx)
       (match type
         ['video (video-callback 'open i)]
         ['audio (audio-callback 'open i)]
         [else (void)])]))
  ;; Create file.
  (when (set-member? (av-output-format-flags format) 'nofile)
    (avio-open (avformat-context-pb output-context) file 'write))
  ;; Write the stream
  (avformat-write-header output-context #f)
  (define remaining-streams (mutable-set))
  (for ([i (in-vector streams)])
    (set-add! remaining-streams i))
  (let loop ()
    (unless (set-empty? remaining-streams)
      (define min-stream
        (for/fold ([min-stream #f])
                  ([i (in-set remaining-streams)])
          (if min-stream
              (match (av-compare-ts (codec-obj-next-pts min-stream)
                                    (avstream-time-base (codec-obj-stream min-stream))
                                    (codec-obj-next-pts i)
                                    (avstream-time-base (codec-obj-stream i)))
                [(or -1 0) min-stream]
                [1 i])
              min-stream)))
      (define stream-finished?
        (match (codec-obj-type min-stream)
          ['video (video-callback 'write min-stream)]
          ['audio (audio-callback 'write min-stream)]
          ['subtitle (subtitle-callback 'write min-stream)]
          [else (void)]))
      (when stream-finished?
        (set-remove! remaining-streams min-stream))
      (loop)))
  (av-write-trailer output-context)
  ;; Clean Up
  (for ([i (in-vector streams)])
    (match i
      [(struct* codec-obj
                ([type type]))
       (match type
         ['video (video-callback 'close i)]
         ['audio (audio-callback 'close i)]
         ['subtitle (subtitle-callback 'close i)])]))
  (when (set-member? (av-output-format-flags format) 'nofile)
    (avio-close (avformat-context-pb output-context)))
  (avformat-free-context output-context))

(define (queue-stream mode obj packet)
  (match obj
    [(struct* codec-obj ([callback-data callback-data]))
     (match mode
       ['init (set-codec-obj-callback-data! (mk-packetqueue))]
       ['loop (packetqueue-put callback-data packet)]
       ['close (packetqueue-put eof)])]))

(define ((dequeue-stream passthrough-proc) mode obj)
  (match obj
    [(struct* codec-obj ([callback-data callback-data]))
     (match mode
       ['init (passthrough-proc mode obj)]
       ['open (passthrough-proc mode obj)]
       ['write (define packet (packetqueue-get callback-data))
               (cond
                 [(eof-object? packet) #f]
                 [else
                  (passthrough-proc mode obj packet)
                  #t])]
       ['close (passthrough-proc mode obj)])]))

(define (link infile
              outfile)
  (define in-bundle (file->stream-bundle infile))
  (define out-bundle (bundle-for-file outfile
                                      (map codec-obj-type in-bundle)))
  (define in-thread
    (thread
     (λ () (demux-stream in-bundle #:by-index-callback queue-stream))))
  (define out-thread
    (thread
     (λ () (mux-stream out-bundle (error "TODO")))))
  (thread-wait in-thread)
  (thread-wait out-thread))