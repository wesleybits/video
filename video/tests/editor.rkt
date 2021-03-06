#lang racket

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

(require rackunit
         racket/gui/base
         wxme
         "../private/editor.rkt")

(let ()
  (define 3ed
    (new video-editor%
         [track-height 10]
         [minimum-width 100]
         [initial-tracks 3]))
  (define new-3ed
    (send 3ed copy-self))
  (check-equal?
   (send 3ed get-min-height)
   30)
  (check-equal?
   (send 3ed get-min-width)
   100)
  (check-equal?
   (send new-3ed get-min-height)
   30)
  (check-equal?
   (send new-3ed get-min-width)
   100)
  (check-equal?
   (syntax->datum (send new-3ed read-special #f #f #f #f))
   (syntax->datum (send 3ed read-special #f #f #f #f))))

(let ()
  (define ned
    (new video-editor%
         [initial-tracks 2]
         [track-height 200]))
  (send ned add-track)
  (check-equal?
   (send ned get-min-height)
   600)
  (send ned delete-track 1)
  (check-equal?
   (send ned get-min-height)
   400))

(let ()
  (define ed
    (new video-editor%))
  (send ed on-default-event (new mouse-event% [event-type 'right-down]))
  (define text-ed
    (new video-text%))
  (send text-ed on-event (new mouse-event% [event-type 'right-down]))
  (define file-ed
    (new video-file%))
  (send file-ed on-event (new mouse-event% [event-type 'right-down])))

(let ()
  (define ed
    (new video-editor% [initial-tracks 2]))
  (send ed insert-video (new video-snip%) 0 5 10)
  (send ed delete-track 0))

(let ()
  (define 4ed
    (new video-editor%
         [track-height 200]
         [minimum-width 500]
         [initial-tracks 4]))
  (check-equal?
   (send 4ed get-min-height)
   800)
  (check-equal?
   (send 4ed get-min-width)
   500)
  (define 4ed-str-out
    (new editor-stream-out-bytes-base%))
  (send 4ed write-to-file (make-object editor-stream-out% 4ed-str-out))
  (define 4ed-str
    (send 4ed-str-out get-bytes))
  (define 4ed-str-in
    (make-object editor-stream-in-bytes-base% 4ed-str))
  (define new-4ed
    (new video-editor%))
  (send new-4ed read-from-file (make-object editor-stream-in% 4ed-str-in))
  (check-equal?
   (send new-4ed get-min-height)
   800)
  (check-equal?
   (send new-4ed get-min-width)
   500))

(let ()
  (define vf (new video-file% [file (build-path "hello.mp4")]))
  (send vf set-file! (build-path "world.mp4"))
  (define vf2 (send vf copy-self))
  (check-equal? (syntax->datum (send vf2 read-special #f #f #f #f))
                (syntax->datum (send vf read-special #f #f #f #f)))
  (check-equal? (send vf2 get-file)
                (send vf get-file)))

(let ()
  (define vs (new video-snip%
                  [editor (new video-editor%)]))
  (define vs2 (send vs copy))
  (define b1 (new editor-stream-out-bytes-base%))
  (define b2 (new editor-stream-out-bytes-base%))
  (send vs2 write (make-object editor-stream-out% b2))
  (send vs write (make-object editor-stream-out% b1))
  (check-equal? (send b1 get-bytes)
                (send b2 get-bytes))
  (define b3 (make-object editor-stream-in-bytes-base% (send b1 get-bytes)))
  (define b4 (make-object editor-stream-in-bytes-base% (send b1 get-bytes)))
  (define b5 (make-object editor-stream-in-bytes-base% (send b1 get-bytes)))
  (define vr (new video-snip-reader%))
  (define vsc (new video-snip-class%))
  (define vs3 (send vsc read (make-object editor-stream-in% b3)))
  (check-equal? (send vr read-header "0" (make-object editor-stream-in% b5))
                (void)))


(let ()
  (define ve (new video-editor%
                  [initial-tracks 3]
                  [track-height 200]))
  (send ve set-track-height! 400)
  (check-equal?
   (send ve get-min-height)
   1200))

(let ()
  (define ve (new video-editor%
                  [initial-tracks 3]
                  [track-height 500]))
  (send ve insert-video (new video-snip%) 2 5 10)
  (send ve delete-track 1)
  (define ve2 (send ve copy-self))
  (define b1 (new editor-stream-out-bytes-base%))
  (define b2 (new editor-stream-out-bytes-base%))
  (send ve write-to-file (make-object editor-stream-out% b1))
  (send ve2 write-to-file (make-object editor-stream-out% b2))
  (check-equal? (send b2 get-bytes)
                (send b1 get-bytes))
  (define b3 (make-object editor-stream-in-bytes-base% (send b1 get-bytes)))
  (define b4 (make-object editor-stream-in-bytes-base% (send b2 get-bytes)))
  (send ve read-from-file (make-object editor-stream-in% b3))
  (check-equal?
   (send ve get-min-height)
   1000))

(let ()
  (define admin (new editor-admin%))
  (define ve (new video-editor%
                  [track-height 10]
                  [initial-tracks 2]))
  (send ve set-admin admin)
  (define vs (new video-snip%
                  [editor (new video-editor%)]))
  (send ve insert-video vs 1 0 10)
  (send ve resize vs 1 1)
  (define ve2 (new video-editor%
                   [track-height 10]
                   [initial-tracks 2]))
  (define vs2 (new video-snip%
                   [editor (new video-editor%)]))
  (send ve2 insert-video vs2 1 0 1)
  (check-equal? (syntax->datum (send ve read-special #f #f #f #f))
                (syntax->datum (send ve2 read-special #f #f #f #f)))
  (define ve3 (new video-editor%
                   [track-height 10]
                   [initial-tracks 2]))
  (define vs3 (new video-snip%
                   [editor (new video-editor%)]))
  (send ve3 insert-video vs3 1 0 10)
  (check-not-equal? (syntax->datum (send ve read-special #f #f #f #f))
                    (syntax->datum (send ve3 read-special #f #f #f #f))) )
  

(let ()
  (define ve (new video-editor%
                  [minimum-width 1000]
                  [initial-tracks 10]
                  [track-height 100]))
  (define dc (new bitmap-dc% [bitmap (make-object bitmap% 1000 1000)]))
  (check-equal? (send ve on-paint #t dc 0 0 1000 1000 0 0 'no-carot)
                (void)))
