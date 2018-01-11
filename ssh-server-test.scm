(use srfi-18)
(include "core.scm")

(define server-sign-pk
  (base64-decode "M84ih/5V5TFvI3DSuMXiSwa5EqUqC7cYM/J09uIpxLU="))
(define server-sign-sk
  (base64-decode (conc "iWtDZXdl/UeN3q7sq2QWN2Ymv3ggveJRBvn1a+rMC5oz"
                       "ziKH/lXlMW8jcNK4xeJLBrkSpSoLtxgz8nT24inEtQ==")))

(define (write-signpk pk)
  (define type "ssh-ed25519")
  ;;(assert (= (string-length pk) 32))
  (write-buflen
   (conc (u2s (string-length type)) type
         (u2s (string-length pk))   pk)))

(define (handle-client ip op)
  (eval `(begin (set! ip ',ip) (set! op ',op)))

  (define ssh (make-ssh ip op))
  (eval `(set! ssh ',ssh))

  (define hellosend "SSH-2.0-klmssh_0.1 testing123") ;; TODO: randomize
  (display (conc hellosend "\r\n") op)
  
  (define helloreceive (read-protocol-exchange ip))
  ;;(print "helloreceive: " (wots (write helloreceive)))

  (define kexsend (wots (kx-payload)))
  ;;(print "kexsend: " (wots (write kexsend)))
  (write-payload ssh kexsend)
  (define kexrecv (read-payload ssh))
  ;;(print "kexrecv: " (wots (write kexrecv)))
  (wifp (open-input-string kexrecv)
        (print "KEXINIT=? " (read-byte))
        (SSH_MSG_KEXINIT))

  (define next-packet (read-payload ssh))

  (define clientpk
    (wifs next-packet
          (print "packet type: " (read-byte))
          (read-buflen)))
  (eval `(set! clientpk ,clientpk))

  (define-values (serversk serverpk)
    (make-curve25519-keypair))

  (define sharedsecret (string->mpint (curve25519-dh serversk clientpk)))
  (eval `(set! K ,sharedsecret))

  (define hash
    (exchange-hash helloreceive hellosend
                   kexrecv kexsend
                   server-sign-pk
                   clientpk serverpk
                   sharedsecret))
  (%ssh-sid-set! ssh hash) ;; first exchange has = session id (unchanged, even after rekeying)
  
  (print "signing " (string->blob hash) " pk " (string->blob server-sign-pk))
  (define signature (substring ((asymmetric-sign (string->blob server-sign-sk)) hash) 0 64))
  (print "signature: " (string->blob signature))


  (write-payload ssh
                 (wots (write-byte (payload-type->int 'kexdh-reply))
                       (write-signpk server-sign-pk)
                       (write-buflen serverpk)
                       (write-signpk signature)))

  (write-payload ssh
                 (wots (write-byte (payload-type->int 'newkeys))))

  (read-payload/expect ssh 'newkeys)

  (define (kex-derive-key id)
    (string->blob (kex-derive-keys64 id sharedsecret hash (ssh-sid ssh))))

  ;;(print "derived key A" (kex-derive-key "A"))
  ;;(print "derived key B" (kex-derive-key "B"))
  (define key-c2s (kex-derive-key "C"))
  (define key-s2c (kex-derive-key "D"))
  ;;(print "derived key E" (kex-derive-key "E"))
  ;;(print "derived key F" (kex-derive-key "F"))


  (define key-c2s-main   (string->blob (substring (blob->string key-c2s) 0 32)))
  (define key-c2s-header (string->blob (substring (blob->string key-c2s) 32 64)))

  (define key-s2c-main   (string->blob (substring (blob->string key-s2c) 0 32)))
  (define key-s2c-header (string->blob (substring (blob->string key-s2c) 32 64)))

  (%ssh-payload-reader-set! ssh (make-payload-reader/chacha20 key-c2s-main key-c2s-header))
  (%ssh-payload-writer-set! ssh (make-payload-writer/chacha20 key-s2c-main key-s2c-header))


  (define packet (read-payload/expect ssh 'service-request))
  (unless (equal? "\x05\x00\x00\x00\fssh-userauth" packet)
    (error "something's not right here"))

  (write-payload ssh "\x06\x00\x00\x00\fssh-userauth")

  ;; write welcome banner
  (quote
   (write-payload ssh (wots (write-byte (payload-type->int 'userauth-banner))
                            (write-buflen "access granted. welcome. don't do evil, do good.\n")
                            (write-buflen "none"))))


  (read-payload/expect ssh 'userauth-request)
  (write-payload ssh (wots (write-byte (payload-type->int 'userauth-success))))

   ;;; e.g.  "Z\x00\x00\x00\asession\x00\x00\x00\x01\x00 \x00\x00\x00\x00\x80\x00"
  (read-payload/expect ssh 'channel-open)

  ;; TODO: parse this properly
  (define channelid "\x00\x00\x00\x01") ;; OpenSSH on arch linux
  (eval `(set! channelid ',channelid))
  ;; (define channelid "\x00\x00\x00\x00") ;; OpenSSH on mac

  (write-payload ssh
                 (wots
                  (write-byte (payload-type->int 'channel-open-confirmation))
                  (display channelid)          ;; sender cid
                  (display "\x00\x00\x00\x01") ;; my cid
                  (display (u2s #x200000))
                  (display (u2s #x008000))))

  (read-payload/expect ssh 'channel-request)

  (write-payload ssh
                 (wots (write-byte (payload-type->int 'channel-data))
                       (display channelid)
                       (write-buflen "CHISSH> ")))

  (write-payload ssh
                 (wots (write-byte (payload-type->int 'channel-success))
                       (display channelid)))


  (write-payload ssh
                 (wots
                  (write-byte (payload-type->int 'channel-request))
                  (display channelid)
                  (write-buflen "exit-status")
                  (display "\x00") ;; «want reply» I think
                  (display "\x00\x00\x00\x06")) ;; exit_status
                 )

  (quote
   (write-payload ssh (wots (write-byte (payload-type->int 'channel-eof))
                            (display channelid))))

  (quote
   (write-payload ssh (wots (write-byte (payload-type->int 'channel-close))
                            (display channelid))))


  (let loop ()
    (read-payload ssh)
    (loop)))

(define (ssh-server-start port)
  (define ss (tcp-listen port))
  (let loop ()
    (receive (ip op) (tcp-accept ss)
      (print "incoming: " ip " " op)
      (thread-start!
       (lambda () (handle-client ip op))))
    (loop)))



