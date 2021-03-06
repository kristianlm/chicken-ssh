(import
 matchable gochan
 (only (chicken port) make-output-port make-input-port with-output-to-string)
 (only srfi-13 string-null?)
 (only srfi-69 make-hash-table hash-table-ref hash-table-set! hash-table-fold hash-table-for-each)
 (only (chicken condition) handle-exceptions current-exception-handler)
 (only (chicken port) make-input-port make-output-port)
 (only srfi-18 make-mutex))

(include "oaat.scm")

(define current-window-size (make-parameter (* 1024 1024)))
(define current-max-ps      (make-parameter 32767))

;; multiple channel objects per session object
(define-record-type <ssh-channel>
  (%make-ssh-channel ssh type  ;; type is almost always "session"
                     lcid rcid ;; same id for sender and receiver
                     gochan-open-response
                     gochan-cmd gochan-request-response
                     gochan-data
                     gochan-close
                     gochan-window-adjust
                     pty
                     max-ps
                     ws/read ws/write) ;; window sizes
  ;; TODO: field for max packet size
  ;; TODO: field for exit-status, exec command?
  ssh-channel?
  (ssh  channel-ssh)
  (type channel-type)
  (lcid  channel-lcid)
  (rcid  channel-rcid      %channel-rcid-set!)
  (gochan-open-response    %channel-gochan-open-response)
  (gochan-cmd              %channel-gochan-cmd)
  (gochan-request-response %channel-gochan-request-response)
  (gochan-data             %channel-gochan-data)
  (gochan-close            %channel-gochan-close)
  (gochan-window-adjust    %channel-gochan-window-adjust)
  (pty                     %channel-pty)
  (max-ps      ssh-channel-max-ps)
  (ws/read  ssh-channel-ws/read  %ssh-channel-ws/read-set!)
  (ws/write ssh-channel-ws/write %ssh-channel-ws/write-set!))

;; single ssh-channel-context object per ssh session object
(define-record-type <ssh-channel-context>
  (%make-ssh-channel-context handlers
                             gochan-open
                             oaat)
  ssh-channel-context?
  (handlers           %scc-handlers)
  (gochan-open        %scc-gochan-open)
  (oaat               %scc-oaat))

(define (make-ssh-channel-context)
  (%make-ssh-channel-context
   (make-hash-table)
   (gochan 1024) ;; channel-open
   (make-oaat)))

(define (%find-free-cid ssh)
  (let ((ht (ssh-channels ssh)))
    (let loop ((n 0))
      (if (hash-table-ref ht n (lambda () #f))
          (loop (+ n 1))
          n))))

(define (make-ssh-channel ssh type rcid lws rws rmax-ps)
  (mutex-lock! (ssh-channels-mutex ssh))
  (let* ((lcid (%find-free-cid ssh))
         (ch (%make-ssh-channel ssh type lcid rcid
                                (gochan 1024) ;; gochan-open-response
                                (gochan 1024) ;; gochan-cmd
                                (gochan 1024) ;; gochan-request-response
                                (gochan 1024) ;; gochan-data
                                (gochan 1024) ;; gochan-close
                                (gochan 1024) ;; gochan-window-adjust
                                (vector #f #f #f #f #f) ;; pty
                                rmax-ps lws rws)))
    (set! (ssh-channel ssh lcid) ch)
    (mutex-unlock! (ssh-channels-mutex ssh))
    ch))

(define (channel-pty-property idx)
  (getter-with-setter (lambda (ch)   (vector-ref  (%channel-pty ch) idx))
                      (lambda (ch v) (vector-set! (%channel-pty ch) idx v))))

(define channel-allow-pty?      (channel-pty-property 0))
(define channel-terminal        (channel-pty-property 1))
(define channel-terminal-width  (channel-pty-property 2))
(define channel-terminal-height (channel-pty-property 3))
(define channel-terminal-modes  (channel-pty-property 4))

(define (channel-close-all-gochans ch p)
  (gochan-close (%channel-gochan-open-response ch) p)
  (gochan-close (%channel-gochan-cmd ch) p)
  (gochan-close (%channel-gochan-request-response ch) p)
  (gochan-close (%channel-gochan-close ch) p)
  (gochan-close (%channel-gochan-window-adjust ch) p))

(define (ensure-ssh-specific! ssh)
  (unless (ssh-specific ssh)
    (ssh-specific-set! ssh (make-ssh-channel-context)))
  (assert (ssh-channel-context? (ssh-specific ssh))))

(define (ssh-handlers ssh)
  (ensure-ssh-specific! ssh)
  (%scc-handlers (ssh-specific ssh)))

;; TODO: (make-vector 256) instead of hash table for speed?
(define ssh-handler
  (getter-with-setter
   (lambda (ssh packet-type #!optional (missing (lambda () (error "internal error: handler not found"))))
     (hash-table-ref  (ssh-handlers ssh) packet-type missing))
   (lambda (ssh packet-type v)
     (hash-table-set! (ssh-handlers ssh) packet-type v))))

(define (ssh-oaat ssh)
  (ensure-ssh-specific! ssh)
  (%scc-oaat (ssh-specific ssh)))

(define (ssh-handle! ssh packet-type proc)
  ;; (when (ssh-handler ssh packet-type (lambda () #f))
  ;;   (error "handler already assigned for " packet-type))
  (set! (ssh-handler ssh packet-type) proc))

(define (%ssh-gochan-channel-open ssh)
  (ensure-ssh-specific! ssh)
  (%scc-gochan-open (ssh-specific ssh)))

(define (ssh-do-handlers! ssh)
  (oaat (ssh-oaat ssh)
        (lambda ()
          (let* ((p (next-payload ssh))
                 (handler (ssh-handler ssh (car p) (lambda () #f))))
            (if handler
                (handler ssh p)
                (ssh-log "ignoring unhandled packet: " (with-output-to-string (lambda () (write p)))))))))

(define (register-channel-handlers! ssh)
  (ensure-ssh-specific! ssh)
  (define (decrement! ch by)
    (let* ((new (- (ssh-channel-ws/read ch) by)))
      (%ssh-channel-ws/read-set! ch new)))

  (ssh-handle! ssh 'disconnect
               (lambda (ssh p)
                 (match p
                   (('disconnect reason-code description language)
                    ;; TODO: keep disconnect reason somewhere
                    (gochan-close (%ssh-gochan-channel-open ssh) p)
                    (mutex-lock! (ssh-channels-mutex ssh))
                    (hash-table-for-each (ssh-channels ssh)
                                         (lambda (k ch)
                                           (channel-close-all-gochans ch p)))
                    (mutex-unlock! (ssh-channels-mutex ssh))))))

  (ssh-handle! ssh 'channel-data
               (lambda (ssh p)
                 (match p
                   (('channel-data cid str)
                    (and-let* ((ch (ssh-channel ssh cid (lambda () (ssh-log "bad remote: 'channel-close on dead channel: " cid) #f))))
                      (decrement! ch (string-length str))
                      (gochan-send (%channel-gochan-data ch)
                                   (list str #f)))))))

  (ssh-handle! ssh 'channel-extended-data
               (lambda (ssh p)
                 (match p
                   (('channel-extended-data cid str idx)
                    (and-let* ((ch (ssh-channel ssh cid (lambda () (ssh-log "bad remote: 'channel-close on dead channel: " cid) #f))))
                      (decrement! ch (string-length str))
                      (gochan-send (%channel-gochan-data ch)
                                   (list str idx)))))))

  (ssh-handle! ssh 'channel-eof
               (lambda (ssh p)
                 (match p
                   (('channel-eof cid)
                    (and-let* ((ch (ssh-channel ssh cid (lambda () (ssh-log "bad remote: 'channel-close on dead channel: " cid) #f))))
                      (gochan-close (%channel-gochan-data ch)))))))

  (ssh-handle! ssh 'channel-close
               (lambda (ssh p)
                 (match p
                   (('channel-close cid)
                    (and-let* ((ch (ssh-channel ssh cid (lambda () (ssh-log "bad remote: 'channel-close on dead channel: " cid) #f))))
                      (let ((chan-close (%channel-gochan-close ch)))
                        (gochan-select
                         ((chan-close -> _ closed)) ;; already closed, do nothing
                         (else ;; forcefully close channel (eof for graceful closing)
                          (channel-close-all-gochans ch #t)
                          ;; obs: this is actually _not_ thread safe,
                          ;; we might send 'channel-close twice like this :-(
                          (unparse-channel-close ssh (channel-rcid ch)))))
                      (gochan-close (%channel-gochan-data ch))
                      (set! (ssh-channel ssh cid) #f))))))

  (ssh-handle! ssh 'channel-window-adjust
               (lambda (ssh p)
                 (match p
                   (('channel-window-adjust cid increment)
                    ;; already in ssh's handler mutex
                    (and-let* ((ch (ssh-channel ssh cid (lambda () (ssh-log "bad remote: 'channel-window-adjust on dead channel: " cid) #f))))
                      (%ssh-channel-ws/write-set!
                       ch (+ (ssh-channel-ws/write ch) increment))

                      ;; we send #t on a channel just to "kick" blocked senders
                      (gochan-send (%channel-gochan-window-adjust ch) #t)))))))

(define (register-server-handlers! ssh)
  (register-channel-handlers! ssh)
  (ssh-handle! ssh 'channel-open
               (lambda (ssh p) (gochan-send (%ssh-gochan-channel-open ssh) p)))

  (ssh-handle! ssh 'channel-request
               (lambda (ssh p)
                 (match p

                   (('channel-request cid 'exec want-reply? cmd)
                    (when want-reply?
                      (unparse-channel-success ssh (channel-rcid (ssh-channel ssh cid))))
                    (gochan-close (%channel-gochan-cmd (ssh-channel ssh cid)) cmd))

                   (('channel-request cid 'shell want-reply?)
                    (when want-reply?
                      (unparse-channel-success ssh (channel-rcid (ssh-channel ssh cid))))
                    ;; hack of the month! pretend #f is #t since "close flag" can't be #f
                    (gochan-close (%channel-gochan-cmd (ssh-channel ssh cid)) #t))

                   (('channel-request cid 'pty-req want-reply? term
                                      width/characters height/rows ;; numbers
                                      width/pixels height/pixels ;; numbers, usuall 0
                                      modes) ;; blob
                    (let ((ch (ssh-channel ssh cid)))
                      (if (channel-allow-pty? ch)
                          (begin
                            (when want-reply? (unparse-channel-success ssh (channel-rcid ch)))
                            (set! (channel-terminal ch) term)
                            (set! (channel-terminal-width ch) width/characters)
                            (set! (channel-terminal-height ch) height/rows)
                            (set! (channel-terminal-modes ch) modes))
                          (begin
                            (when want-reply? (unparse-channel-failure ssh (channel-rcid ch)))))))

                   (('channel-request cid 'window-change want-reply?
                                      width/characters height/rows ;; numbers
                                      width/pixels     height/pixels) ;; numbers, usually 0
                    (let ((ch (ssh-channel ssh cid)))
                      (if (channel-allow-pty? ch)
                          (begin
                            (when want-reply? (unparse-channel-success ssh (channel-rcid ch)))
                            (set! (channel-terminal-width ch) width/characters)
                            (set! (channel-terminal-height ch) height/rows))
                          (begin
                            (when want-reply? (unparse-channel-failure ssh (channel-rcid ch)))))))

                   (('channel-request cid _ want-reply? . rest)
                    (when want-reply?
                      (unparse-channel-failure ssh (channel-rcid (ssh-channel ssh cid)))))))))

(define (register-client-handlers! ssh)
  (register-channel-handlers! ssh)
  (ssh-handle! ssh 'channel-open-confirmation
               (lambda (ssh p)
                 (match p
                   (('channel-open-confirmation cid . _)
                    (gochan-send (%channel-gochan-open-response (ssh-channel ssh cid)) p)))))

  (ssh-handle! ssh 'channel-open-failure
               (lambda (ssh p)
                 (match p
                   (('channel-open-failure cid . _)
                    (and-let* ((ch  (ssh-channel ssh cid (lambda () (ssh-log "bad remote: open-failure on dead channel: " cid) cid))))
                      (gochan-send (%channel-gochan-open-response ch) p))))))

  (ssh-handle! ssh 'channel-success
               (lambda (ssh p)
                 (match p
                   (('channel-success cid)
                    (and-let* ((ch (ssh-channel ssh cid (lambda () (ssh-log "bad remote: 'channel-success on dead channel: " cid) #f))))
                      (gochan-send (%channel-gochan-request-response ch)
                                   'channel-success))))))

  (ssh-handle! ssh 'channel-failure
               (lambda (ssh p)
                 (match p
                   (('channel-failure cid)
                    (and-let* ((ch (ssh-channel ssh cid (lambda () (ssh-log "bad remote: 'channel-failure on dead channel: " cid) #f))))
                      (gochan-send (%channel-gochan-request-response ch)
                                   'channel-failure)))))))


;; get (or wait for) exec/shell channel-request command
(define (channel-command ch)
  (define chan-cmd (%channel-gochan-cmd ch))

  (let loop ()
    (gochan-select
     ((chan-cmd -> _ cmd)
      (if (string? cmd) ;; see hacky "close flag" in handler
          cmd
          #f))
     (else (ssh-do-handlers! (channel-ssh ch))
           (loop)))))

;; block and wait for channel-open
(define (channel-accept ssh #!key pty)
  (define chan-open (%ssh-gochan-channel-open ssh))
  (register-server-handlers! ssh)

  ;; allow channel-close, channel-eof, channel-request
  (let loop ()
    (gochan-select
     ((chan-open -> msg closed)
      (if closed
          #!eof
          (match msg
            (('channel-open type rcid rws rmax-ps)
             (let ((lws (current-window-size))
                   (lmax-ps (current-max-ps)))
               (define ch (make-ssh-channel ssh type rcid lws rws rmax-ps))
               (set! (channel-allow-pty? ch) pty)
               (unparse-channel-open-confirmation ssh rcid (channel-lcid ch)
                                                  lws lmax-ps)
                ;; force server to process exec/shell requests
                ;; immediately to avoid hangs on client-side
               (channel-command ch)
               ch)))))
     (else (ssh-do-handlers! ssh)
           (loop)))))

(define (channel-open ssh #!key (type "session"))
  (register-client-handlers! ssh)

  (let* ((lws (current-window-size))
         (lmax-ps (current-max-ps)))

    ;;                                     ,--rcid ,--rws unknown
    (define ch (make-ssh-channel ssh type #f lws #f lmax-ps))
    (define lcid (channel-lcid ch))
    (unparse-channel-open ssh type lcid lws lmax-ps)
    (define chan-open-response (%channel-gochan-open-response ch))

    (let loop ()
      (gochan-select
       ((chan-open-response -> msg)
        (match msg
          (('channel-open-confirmation cid rcid rws rmax-ps)
           (assert (= cid lcid))
           (%channel-rcid-set! ch rcid)
           (%ssh-channel-ws/write-set! ch rws)
           ch)
          (('channel-open-failure cid reason description language)
           (assert (= cid lcid))
           (error "cannot open channel" reason description language))))
       (else (ssh-do-handlers! ssh)
             (loop))))))

(define (channel-exec ssh cmd #!optional (ch (channel-open ssh)))
  (define chan-request-response (%channel-gochan-request-response ch))
  (define chan-cmd (%channel-gochan-cmd ch))
  (gochan-close chan-cmd cmd)
  (unparse-channel-request ssh (channel-rcid ch) 'exec #t cmd)

  (let loop ()
    (gochan-select
     ((chan-request-response -> msg closed)
      (if closed
          #!eof
          (match msg
            ('channel-success ch)
            ('channel-failure (error 'channel-exec "remote side denied exec request")))))
     (else (ssh-do-handlers! ssh)
           (loop)))))

(define (channel-read ch)
  (define chan-data (%channel-gochan-data ch))

  ;; give client more window space. TODO: make increment customizable
  (when (< (ssh-channel-ws/read ch) (current-window-size))
    (let ((increment (current-window-size)))
     (%ssh-channel-ws/read-set! ch (+ (ssh-channel-ws/read ch) increment))
     (unparse-channel-window-adjust (channel-ssh ch) (channel-rcid ch) increment)))

  (let loop ()
    (gochan-select
     ((chan-data -> msg closed)
      (if closed
          (values #!eof #f)
          (values (car msg) (cadr msg))))
     (else (ssh-do-handlers! (channel-ssh ch))
           (loop)))))

(define (channel-write ch str #!optional (extended #f))
  (define chan-close (%channel-gochan-close ch))
  (define chan-window-adjust (%channel-gochan-window-adjust ch))

  (gochan-select
   ((chan-close -> _ closed)
    (error "cannot write to locally closed channel" ch))
   (else)) ;; still open, do nothing

  (define max-ps (min (ssh-channel-max-ps ch) 32768))
  (define (send! str)
    (let ((extended (if (eq? 'stderr extended) 1 extended)))
      (if extended
          (unparse-channel-extended-data (channel-ssh ch)
                                         (channel-rcid ch)
                                         extended
                                         str)
          (unparse-channel-data (channel-ssh ch)
                                (channel-rcid ch)
                                str)))
    ;; TODO: mutex here
    (%ssh-channel-ws/write-set! ch (- (ssh-channel-ws/write ch)
                                      (string-length str))))

  (let loop ((str str))
    (define limit (min max-ps (ssh-channel-ws/write ch)))
    (if (<= (string-length str) limit)
        (unless (string-null? str) ;; room for all
          (send! str))
        (if (> limit 0) ;; room for some
            (begin
              (send! (substring str 0 limit))
              (loop (substring str limit)))
            ;; room for nothing, wait for ws adjust
            (let retry ()
              (gochan-select
               ;; TODO: make this more efficient? any buffered messages
               ;; have no affect.
               ((chan-window-adjust -> _) (loop str))
               ;; remote side closes instead of giving us a bigger window
               ;; size. what should we really do here?
               ((chan-close -> _ fail)
                (error 'channel-write "remote side closed channel while waiting for window size" ch))
               (else (ssh-do-handlers! (channel-ssh ch))
                     (retry))))))))

(define (channel-eof ch)
  (unparse-channel-eof (channel-ssh ch) (channel-rcid ch)))

(define (channel-close ch)
  (define chan-close (%channel-gochan-close ch))
  (gochan-select
   ((chan-close -> _ closed))
   (else ;; not already closed, send close both ends
    (unparse-channel-close (channel-ssh ch) (channel-rcid ch))
    (gochan-close chan-close))))


;; ==================== channel ports ====================

(define (channel-input-port ch)
  (let ((buffer "") (pos 0)) ;; buffer is #f for #!eof
    (make-input-port
     (lambda () ;; read
       (let loop ()
         (if (>= pos (string-length buffer))
             (receive (data idx) (channel-read ch)
               (if (eof-object? data)
                   #!eof
                   (begin
                     (set! buffer data)
                     (set! pos 0)
                     (loop))))
             (let ((c (string-ref buffer pos)))
               (set! pos (+ 1 pos))
               c))))
     (lambda () #t) ;; ready?
     void))) ;; close

(define (channel-output-port ch)
  (make-output-port
   (lambda (str)
     (channel-write ch str #f))
   (lambda ()
     (channel-eof ch)
     (channel-close ch))))

;; tempted to use this? see examples/server-repl.scm for some tips.
(define (channel-error-port ch)
  (let ((cep (current-error-port)))
    (make-output-port
     (lambda (str)
       (channel-write ch str 'stderr))
     (lambda ()
       (channel-eof ch)
       (channel-close ch)))))

(define (with-channel-ports ch thunk)
  (parameterize ((current-output-port (channel-output-port ch))
                 (current-input-port  (channel-input-port ch)))
    (thunk)
    (close-output-port (current-output-port))
    (close-input-port  (current-input-port))))

(define (with-channel-ports* ch thunk)
  ;; obs: closing output port above also closes error port here :-(
  (parameterize ((current-error-port  (channel-error-port ch)))
    (with-channel-ports ch thunk)
    (close-output-port (current-error-port))))
