;;;; swank-kawa.scm --- Swank server for Kawa
;;;
;;; Copyright (C) 2007  Helmut Eller
;;;
;;; This file is licensed under the terms of the GNU General Public
;;; License as distributed with Emacs (press C-h C-c to view it).

;;;; Installation 
;;
;; 1. You need Kawa (SVN version) 
;;    and a Sun JVM with debugger support.
;; 2. Compile this file with:
;;      kawa -e '(compile-file "swank-kawa.scm" "swank-kawa")'
;; 3. Add something like this to your .emacs:
#|
;; Kawa and the debugger classes (tools.jar) must be in the classpath.
;; You also need to start the debug agent.
(setq slime-lisp-implementations
      '((kawa ("java"
	       "-cp" "/opt/kawa/kawa-svn:/opt/java/jdk1.6.0/lib/tools.jar"
	       "-agentlib:jdwp=transport=dt_socket,server=y,suspend=n"
	       "kawa.repl")
              :init kawa-slime-init)))

(defun kawa-slime-init (file _)
  (setq slime-protocol-version nil)
  (let ((zip ".../slime/contrib/swank-kawa.zip")) ; <-- insert the right path
    (format "%S\n"
            `(begin (load ,(expand-file-name zip)) (start-swank ,file)))))
|#
;; 4. Start everything with  M-- M-x slime kawa
;;
;;

;;;; Module declaration

;; (module-export start-swank create-swank-server swank-java-source-path)

(module-static #t)

(module-compile-options
 :warn-invoke-unknown-method #t
 :warn-undefined-variable #t)

(require 'hash-table)


;;;; Macros ()

(define-syntax df
  (syntax-rules (=>)
    ((df name (args ... => return-type) body ...)
     (define (name args ...) :: return-type body ...))
    ((df name (args ...) body ...)
     (define (name args ...) body ...))))

(define-syntax fun
  (syntax-rules ()
    ((fun (args ...) body ...)
     (lambda (args ...) body ...))))

(define-syntax fin
  (syntax-rules ()
    ((fin body handler ...)
     (try-finally body (seq handler ...)))))

(define-syntax seq
  (syntax-rules ()
    ((seq body ...)
     (begin body ...))))

(define-syntax esc
  (syntax-rules ()
    ((esc abort body ...)
     (let* ((key (<symbol>))
            (abort (lambda (val) (throw key val))))
       (catch key 
              (lambda () body ...)
              (lambda (key val) val))))))

(define-syntax !
  (syntax-rules ()
    ((! name obj args ...)
     (invoke obj 'name args ...))))

(define-syntax !!
  (syntax-rules ()
    ((!! name1 name2 obj args ...)
     (! name1 (! name2 obj args ...)))))

(define-syntax @
  (syntax-rules ()
    ((@ name obj)
     (field obj 'name))))

(define-syntax while
  (syntax-rules ()
    ((while exp body ...)
     (do () ((not exp)) body ...))))

(define-syntax dotimes 
  (syntax-rules ()
    ((dotimes (i n result) body ...)
     (let ((max :: <int> n))
       (do ((i :: <int> 0 (1+ i)))
           ((= i max) result)
           body ...)))
    ((dotimes (i n) body ...)
     (dotimes (i n #f) body ...))))

(define-syntax dolist 
  (syntax-rules ()
    ((dolist (e list) body ...)
     (for-each (lambda (e) body ...) list))
    ((dolist ((e type) list) body ...)
     (for-each (lambda ((e type)) body ...) list)
     )))

(define-syntax for
  (syntax-rules ()
    ((for ((var iterable)) body ...)
     (let ((iter (! iterator iterable)))
       (while (! has-next iter)
         (let ((var (! next iter)))
           body ...))))))

(define-syntax packing
  (syntax-rules ()
    ((packing (var) body ...)
     (let ((var '()))
       (let ((var (lambda (v) (set! var (cons v var)))))
         body ...)
       (reverse! var)))))

;;(define-syntax packing
;;  (syntax-rules ()
;;    ((packing (var) body ...)
;;     (let* ((var '()))
;;       (let-syntax ((var (syntax-rules ()
;;                           ((var v)
;;                            (set! var (cons v var))))))
;;                   body ...)
;;       (reverse var)))))

;;(define-syntax loop
;;  (syntax-rules (for = then collect until)
;;    ((loop for var = init then step until test collect exp)
;;     (packing (pack) 
;;       (do ((var init step))
;;           (test)
;;         (pack exp))))
;;    ((loop while test collect exp)
;;     (packing (pack) (while test (pack exp))))))

(define-syntax with
  (syntax-rules ()
    ((with (vars ... (f args ...)) body ...)
     (f args ... (lambda (vars ...) body ...)))))

(define-syntax pushf 
  (syntax-rules ()
    ((pushf value var)
     (set! var (cons value var)))))

(define-syntax ==
  (syntax-rules ()
    ((== x y)
     (eq? x y))))

(define-syntax set
  (syntax-rules ()
    ((set x y)
     (let ((tmp y))
       (set! x tmp)
       tmp))
    ((set x y more ...)
     (begin (set! x y) (set more ...)))))

(define-syntax assert
  (syntax-rules ()
    ((assert test)
     (seq
       (when (not test)
         (error "Assertion failed" 'test))
       'ok))
    ((assert test fstring args ...)
     (seq
       (when (not test)
         (error "Assertion failed" 'test (format #f fstring args ...)))
       'ok))))

(define-syntax mif
  (syntax-rules (unquote quote _ ::)
    ((mif ('x value) then else)
     (if (equal? 'x value) then else))
    ((mif (,x value) then else)
     (if (eq? x value) then else))
    ((mif (() value) then else)
     (if (null? value) then else))
    ((mif ((pattern . rest) value) then else)
     (let ((tmp value)
           (fail (lambda () else)))
       (if (pair? tmp)
           (mif (pattern (car tmp))
                (mif (rest (cdr tmp)) then (fail))
                (fail))
           (fail))))
    ((mif (_ value) then else)
     then)
    ((mif (var value) then else)
     (let ((var value)) then))
    ((mif (pattern value) then)
     (mif (pattern value) then (values)))))

(define-syntax mcase
  (syntax-rules ()
    ((mcase exp (pattern body ...) more ...)
     (let ((tmp exp))
       (mif (pattern tmp)
            (begin body ...)
            (mcase tmp more ...))))
    ((mcase exp) (error "mcase failed" exp))))

(define-syntax mlet
  (syntax-rules ()
    ((mlet (pattern value) body ...)
     (let ((tmp value))
       (mif (pattern tmp)
            (begin body ...)
            (error "mlet failed" tmp))))))

(define-syntax mlet* 
  (syntax-rules ()
    ((mlet* () body ...) (begin body ...))
    ((mlet* ((pattern value) ms ...) body ...)
     (mlet (pattern value) (mlet* (ms ...) body ...)))))

(define-syntax typecase 
  (syntax-rules (::)
    ((typecase var (type body ...) ...)
     (cond ((instance? var type) 
            (let ((var :: type var))
              body ...))
           ...
           (else (error "typecase failed" var 
                        (! getClass (as <object> var))))))))

(define-syntax ignore-errors
  (syntax-rules ()
    ((ignore-errors body ...)
     (try-catch (begin body ...)
                (v <java.lang.Exception> #f)))))

;;(define-syntax dc
;;  (syntax-rules ()
;;    ((dc name () %% (props ...) prop more ...)
;;     (dc name () %% (props ... (prop <object>)) more ...))
;;    ;;((dc name () %% (props ...) (prop type) more ...)
;;    ;; (dc name () %% (props ... (prop type)) more ...))
;;    ((dc name () %% ((prop type) ...))
;;     (define-simple-class name () 
;;                          ((*init* (prop :: type) ...)
;;                           (set (field (this) 'prop) prop) ...)
;;                          (prop :type type) ...))
;;    ((dc name () props ...)
;;     (dc name () %% () props ...))))


;;;; Aliases

(define-alias <server-socket> <java.net.ServerSocket>)
(define-alias <socket> <java.net.Socket>)
(define-alias <in> <java.io.InputStreamReader>)
(define-alias <out> <java.io.OutputStreamWriter>)
(define-alias <file> <java.io.File>)
(define-alias <str> <java.lang.String>)
(define-alias <builder> <java.lang.StringBuilder>)
(define-alias <throwable> <java.lang.Throwable>)
(define-alias <source-error> <gnu.text.SourceError>)
(define-alias <module-info> <gnu.expr.ModuleInfo>)
(define-alias <iterable> <java.lang.Iterable>)
(define-alias <thread> <java.lang.Thread>)
(define-alias <queue> <java.util.concurrent.LinkedBlockingQueue>)
(define-alias <vm> <com.sun.jdi.VirtualMachine>)
(define-alias <mirror> <com.sun.jdi.Mirror>)
(define-alias <value> <com.sun.jdi.Value>)
(define-alias <thread-ref> <com.sun.jdi.ThreadReference>)
(define-alias <obj-ref> <com.sun.jdi.ObjectReference>)
(define-alias <array-ref> <com.sun.jdi.ArrayReference>)
(define-alias <str-ref> <com.sun.jdi.StringReference>)
(define-alias <meth-ref> <com.sun.jdi.Method>)
(define-alias <class-ref> <com.sun.jdi.ClassType>)
(define-alias <frame> <com.sun.jdi.StackFrame>)
(define-alias <field> <com.sun.jdi.Field>)
(define-alias <local-var> <com.sun.jdi.LocalVariable>)
(define-alias <location> <com.sun.jdi.Location>)
(define-alias <ref-type> <com.sun.jdi.ReferenceType>)
(define-alias <event> <com.sun.jdi.event.Event>)
(define-alias <exception-event> <com.sun.jdi.event.ExceptionEvent>)
(define-alias <step-event> <com.sun.jdi.event.StepEvent>)
(define-alias <env> <gnu.mapping.Environment>)

(define-simple-class <chan> ()
  (owner :: <thread> :init (java.lang.Thread:currentThread))
  (peer :: <chan>)
  (queue :: <queue> :init (<queue>))
  (lock :init (<object>)))


;;;; Entry Points

(df create-swank-server (port-number) 
  (setup-server port-number announce-port))

(df start-swank (port-file)
  (let ((announce (fun ((socket <server-socket>))
                    (with (f (call-with-output-file port-file))
                      (format f "~d\n" (! get-local-port socket))))))
    (spawn (fun ()
             (setup-server 0 announce)))))

(df setup-server ((port-number <int>) announce)
  (! set-name (current-thread) "swank")
  (let ((s (<server-socket> port-number)))
    (announce s)
    (let ((c (! accept s)))
      (! close s)
      (log "connection: ~s\n"  c)
      (fin (dispatch-events c)
        (log "closing socket: ~a\n" s)
        (! close c)))))

(df announce-port ((socket <server-socket>))
  (log "Listening on port: ~d\n" (! get-local-port socket)))


;;;; Event dispatcher

;; for debugging
(define the-vm #f)

(df dispatch-events ((s <socket>))
  (mlet* ((charset "iso-8859-1")
          (ins (<in> (! getInputStream s) charset))
          (outs (<out> (! getOutputStream s) charset))
          ((in . _) (spawn/chan/catch (fun (c) (reader ins c))))
          ((out . _) (spawn/chan/catch (fun (c) (writer outs c))))
          ((dbg . _) (spawn/chan/catch vm-monitor))
          (user-env 
           (<gnu.mapping.InheritingEnvironment>
            "user" (interaction-environment))
           ;;(interaction-environment)
           )
          ((listener . _)
           (spawn/chan (fun (c) (listener c user-env))))
          (inspector #f)
          (threads '())
          (repl-thread #f)
          (extra '())
          (vm (let ((vm #f)) (fun () (or vm (rpc dbg `(get-vm)))))))
    (while #t
      (mlet ((c . event) (recv* (append (list in out dbg listener)
                                        (if inspector (list inspector) '())
                                        (map car threads)
                                        extra)))
        ;;(log "event: ~s\n" event)
        (mcase (list c event)
          ((_ (':emacs-rex ('|swank:debugger-info-for-emacs| from to)
                           pkg thread id))
           (send dbg `(debug-info ,thread ,from ,to ,id)))
          ((_ (':emacs-rex ('|swank:throw-to-toplevel|) pkg thread id))
           (send dbg `(throw-to-toplevel ,thread ,id)))
          ((_ (':emacs-rex ('|swank:sldb-continue|) pkg thread id))
           (send dbg `(thread-continue ,thread ,id)))
          ((_ (':emacs-rex ('|swank:frame-source-location-for-emacs| frame)
                           pkg thread id))
           (send dbg `(frame-src-loc ,thread ,frame ,id)))
          ((_ (':emacs-rex ('|swank:frame-locals-for-emacs| frame)
                           pkg thread id))
           (send dbg `(frame-locals ,thread ,frame ,id)))
          ((_ (':emacs-rex ('|swank:frame-catch-tags-for-emacs| frame)
                           pkg thread id))
           (send out `(:return (:ok ()) ,id)))
          ((_ (':emacs-rex ('|swank:backtrace| from to) pkg thread id))
           (send dbg `(thread-frames ,thread ,from ,to ,id)))
          ((_ (':emacs-rex ('|swank:list-threads|) pkg thread id))
           (send dbg `(list-threads ,id)))
          ((_ (':emacs-rex ('|swank:debug-nth-thread| n) _  _ _))
           (send dbg `(debug-nth-thread ,n)))
          ((_ (':emacs-rex ('|swank:init-inspector| str . _) pkg _ id))
           (set inspector (make-inspector user-env (vm)))
           (send inspector `(init ,str ,id)))
          ((_ (':emacs-rex ('|swank:inspect-frame-var| frame var) 
                           pkg thread id))
           (mlet ((im . ex) (chan))
             (set inspector (make-inspector user-env (vm)))
             (send dbg `(get-local ,ex ,thread ,frame ,var))
             (send inspector `(init-mirror ,im ,id))))
          ((_ (':emacs-rex ('|swank:inspect-current-condition|) pkg thread id))
           (mlet ((im . ex) (chan))
             (set inspector (make-inspector user-env (vm)))
             (send dbg `(get-exception ,ex ,thread))
             (send inspector `(init-mirror ,im ,id))))
          ((_ (':emacs-rex ('|swank:inspect-nth-part| n) pkg _ id))
           (send inspector `(inspect-part ,n ,id)))
          ((_ (':emacs-rex ('|swank:inspector-pop|) pkg _ id))
           (send inspector `(pop ,id)))
          ((_ (':emacs-rex ('|swank:quit-inspector|) pkg _ id))
           (send inspector `(quit ,id)))
          ((_ (':emacs-interrupt id))
           (let* ((vm (vm))
                  (t (find-thread id (map cdr threads) repl-thread vm)))
             (send dbg `(debug-thread ,t))))
          ((_ (':emacs-rex form _ _ id))
           (send listener `(,form ,id)))
          ((_ ('get-vm c))
           (send dbg `(get-vm ,c)))
          ((_ ('get-channel c))
           (mlet ((im . ex) (chan))
             (pushf im extra)
             (send c ex)))
          ((_ ('forward x))
           (send out x))
          ((_ ('set-listener x))
           (set repl-thread x))
          ((_ ('publish-vm vm))
           (set the-vm vm))
          )))))

(df find-thread (id threads listener (vm <vm>))
  (cond ((== id :repl-thread) listener)
        ((== id 't) (if (null? threads) 
                        listener 
                        (vm-mirror vm (car threads))))
        (#t 
         (let ((f (find-if threads 
                      (fun (t :: <thread>)
                        (= id (! uniqueID 
                                 (as <thread-ref> (vm-mirror vm t)))))
                      #f)))
           (cond (f (vm-mirror vm f))
                 (#t listener))))))


;;;; Reader thread

(df reader ((in <in>) (c <chan>))
  (! set-name (current-thread) "swank-reader")
  (define-namespace ReadTable "class:gnu.kawa.lispexpr.ReadTable")
  (ReadTable:setCurrent (ReadTable:createInitial)) ; ':' not special
  (while #t
    (send c (decode-message in))))

(df decode-message ((in <in>) => <list>)
  (let* ((header (read-chunk in 6))
         (len (java.lang.Integer:parseInt header 16)))
    (call-with-input-string (read-chunk in len) read)))

(df read-chunk ((in <in>) (len <int>) => <str>)
  (let* ((chars (<char[]> :length len))
         (count (! read in chars)))
    (assert (= count len) "count: ~d len: ~d" count len)
    (<str> chars)))


;;;; Writer thread

(df writer ((out <out>) (c <chan>))
  (! set-name (current-thread) "swank-writer")
  (while #t
    (encode-message out (recv c))))

(df encode-message ((out <out>) (message <list>))
  (let ((builder (<builder> (as <int> 512))))
    (print-for-emacs message builder)
    (! write out (! toString (format "~6,'0x" (! length builder))))
    (! write out builder)
    (! flush out)))

(df print-for-emacs (obj (out <builder>))
  (let ((pr (fun (o) (! append out (! toString (format "~s" o)))))
        (++ (fun ((s <string>)) (! append out (! toString s)))))
    (cond ((null? obj) (++ "nil"))
          ((string? obj) (pr obj))
          ((number? obj) (pr obj))
          ((keyword? obj) (++ ":") (! append out (to-str obj)))
          ((symbol? obj) (pr obj))
          ((pair? obj)
           (++ "(")
           (let loop ((obj obj))
             (print-for-emacs (car obj) out)
             (let ((cdr (cdr obj)))
               (cond ((null? cdr) (++ ")"))
                     ((pair? cdr) (++ " ") (loop cdr))
                     (#t (++ " . ") (print-for-emacs cdr out) (++ ")"))))))
          (#t (error "Unprintable object" obj)))))

;;;; SLIME-EVAL

(df eval-for-emacs ((form <list>) env (id <int>) (c <chan>))
  ;;(! set-uncaught-exception-handler (current-thread)
  ;;   (<ucex-handler> (fun (t e) (reply-abort c id))))
  (reply c (%eval form env) id))

(define-constant slime-funs (tab))

(df %eval (form env)
  (apply (lookup-slimefun (car form)) env (cdr form)))

(df lookup-slimefun ((name <symbol>))
  ;; name looks like '|swank:connection-info|
  (let* ((str (symbol->string name))
         (sub (substring str 6 (string-length str))))
    (or (get slime-funs (string->symbol sub) #f)
        (ferror "~a not implemented" sub))))
                         
(define-syntax defslimefun 
  (syntax-rules ()
    ((defslimefun name (args ...) body ...)
     (seq
       (df name (args ...) body ...)
       (put slime-funs 'name name)))))

(defslimefun connection-info ((env <env>))
  (let ((prop java.lang.System:getProperty))
  `(:pid 
    0 
    :style :spawn
    :lisp-implementation (:type "Kawa" :name "kawa" 
                                :version ,(scheme-implementation-version))
    :machine (:instance ,(prop "java.vm.name") :type ,(prop "os.name")
                        :version ,(prop "java.runtime.version"))
    :features ()
    :package (:name "??" :prompt ,(! getName env)))))

 
;;;; Listener

(df listener ((c <chan>) (env <env>))
  (! set-name (current-thread) "listener")
  (log "listener: ~s ~s ~s ~s\n" 
       (current-thread) ((current-thread):hashCode) c env)
  (let ((out (rpc c `(get-channel))))
    (set (current-output-port) (make-swank-outport out)))
  (let ((vm (as <vm> (rpc c `(get-vm)))))
    (enable-uncaught-exception-events vm)
    (send c `(set-listener ,(vm-mirror vm (current-thread)))))
  (listener-loop c env))

(df listener-loop ((c <chan>) (env <env>))
  (while (not (nul? c))
    ;;(log "listener-loop: ~s ~s\n" (current-thread) c)
    (mlet ((form id) (recv c))
      (let ((restart (fun ()
                       (reply-abort c id)
                       (send (car (spawn/chan
                                   (fun (cc) 
                                     (listener (recv cc) env)))) 
                             c)
                       (set c #!null))))
        (! set-uncaught-exception-handler (current-thread)
           (<ucex-handler> (fun (t e) (restart))))
        (try-catch
         (let* ((val (%eval form env)))
           (force-output)
           (reply c val id))
         (ex <listener-abort>
             (let ((flag (java.lang.Thread:interrupted)))
               (log "listener-abort: ~s ~a\n" ex flag))
             (restart)))))))

(defslimefun interactive-eval (env str)
  (values-for-echo-area (eval (read-from-string str) env)))

(defslimefun interactive-eval-region (env (s <string>))
  (with (port (call-with-input-string s))
    (values-for-echo-area
     (let next ((result (values)))
       (let ((form (read port)))
         (cond ((== form #!eof) result)
               (#t (next (eval form env)))))))))

(defslimefun listener-eval (env string)
  (let* ((form (read-from-string string))
         (list (values-to-list (eval form env))))
  `(:values ,@(map pprint-to-string list))))
  
(df call-with-abort (f)
  (try-catch (f) (ex <throwable> (exception-message ex))))

(df exception-message ((ex <throwable>))
  (typecase ex
    (<kawa.lang.NamedException> (! to-string ex))
    (<throwable> (format "~a: ~a"
                         (class-name-sans-package ex)
                         (! getMessage ex)))))

(df values-for-echo-area (values)
  (let ((values (values-to-list values)))
    (format "~:[=> ~{~s~^, ~}~;; No values~]" (null? values) values)))

;;;; Compilation

(define-constant compilation-messages (<gnu.text.SourceMessages>))

(defslimefun compile-file-for-emacs (env (filename <string>) load?)
  (let ((zip (cat (path-sans-extension (filepath filename)) ".zip")))
    (wrap-compilation 
     (fun () (kawa.lang.CompileFile:read filename compilation-messages))
     zip (if (lisp-bool load?) env #f) #f)))

(df wrap-compilation (f zip env delete?)
  (! clear compilation-messages)
  (let ((start-time (current-time)))
    (try-catch
     (let ((c (as <gnu.expr.Compilation> (f))))
       (! compile-to-archive c (! get-module c) zip))
     (ex <throwable>
         (log "error during compilation: ~a\n" ex)
         (! error compilation-messages (as <char> #\f)
            (to-str (exception-message ex)) #!null)))
    (log "compilation done.\n")
    (when (and env
               (zero? (! get-error-count compilation-messages)))
      (eval `(load ,zip) env))
    (when delete?
      (ignore-errors (delete-file zip)))
    (let ((end-time (current-time)))
      (list 'nil (format "~3f" (/ (as <double> (- end-time start-time))
                                  1000))))))

(defslimefun compile-string-for-emacs (env string buffer offset dir)
  (wrap-compilation
   (fun ()
     (let ((c (as <gnu.expr.Compilation>
                  (call-with-input-string 
                   string
                   (fun ((p <gnu.mapping.InPort>))
                     (! set-path p 
                        (format "~s" 
                                `(buffer ,buffer offset ,offset str ,string)))
                     (kawa.lang.CompileFile:read p compilation-messages))))))
       (let ((o (@ currentOptions c)))
         (! set o "warn-invoke-unknown-method" #t)
         (! set o "warn-undefined-variable" #t))
       (let ((m (! getModule c)))
         (! set-name m (format "<emacs>:~a/~a" buffer (current-time))))
       c))
   "/tmp/kawa-tmp.zip" env #t))

(defslimefun compiler-notes-for-emacs (env) 
  (packing (pack)
    (do ((e (! get-errors compilation-messages) (@ next e)))
        ((nul? e))
      (pack (source-error>elisp e)))))

(df source-error>elisp ((e <source-error>) => <list>)
  (list :message (to-string (@ message e))
        :severity (case (integer->char (@ severity e))
                    ((#\e #\f) :error)
                    ((#\w) :warning)
                    (else :note))
        :location (error-loc>elisp e)))

(df error-loc>elisp ((e <source-error>))
  (cond ((! starts-with (@ filename e) "(buffer ")
         (mlet (('buffer b 'offset o 'str s) (read-from-string (@ filename e)))
           `(:location (:buffer ,b)
                       (:position ,(+ o (line>offset (1- (@ line e)) s)
                                      (1- (@ column e))))
                       nil)))
        (#t
         `(:location (:file ,(to-string (@ filename e)))
                     (:line ,(@ line e) ,(1- (@ column e)))
                     nil))))

(df line>offset ((line <int>) (s <str>) => <int>)
  (let ((offset :: <int> -1))
    (dotimes (i line)
      (set offset (! index-of s (as <char> #\newline) (as <int> (1+ offset))))
      (assert (>= offset 0)))
    (log "line=~a offset=~a\n" line offset)
    offset))

;; (let ((offset -1)) (! index-of "\n" (as <char> #\newline) (as <int> (1+ offset))))

(defslimefun load-file (env filename)
  (format "~s\n" (eval `(load ,filename) env)))

;;;; Completion

(defslimefun simple-completions (env (pattern <str>) _)
  (let* ((env (as <gnu.mapping.InheritingEnvironment> env))
         (matches (packing (pack)
                    (let ((iter (! enumerate-all-locations env)))
                      (while (! has-next iter)
                        (let ((l (! next-location iter)))
                          (typecase l
                            (<gnu.mapping.NamedLocation>
                             (let ((name (!! get-name get-key-symbol l)))
                               (when (! starts-with name pattern)
                                 (pack name)))))))))))
    `(,matches ,(cond ((null? matches) pattern)
                      (#t (fold+ common-prefix matches))))))

(df common-prefix ((s1 <str>) (s2 <str>) => <str>)
  (let ((limit (min (! length s1) (! length s2))))
    (let loop ((i 0))
      (cond ((or (= i limit)
                 (not (== (! char-at s1 i)
                          (! char-at s2 i))))
             (! substring s1 0 i))
            (#t (loop (1+ i)))))))

(df fold+ (fn list)
  (let loop ((s (car list))
             (l (cdr list)))
    (cond ((null? l) s)
          (#t (loop (fn s (car l)) (cdr l))))))

;;; Quit

(defslimefun quit-lisp (env)
  (exit))

;;;; Dummy defs

(defslimefun operator-arglist (#!rest y) '())
(defslimefun buffer-first-change (#!rest y) '())

;;;; M-.

(defslimefun find-definitions-for-emacs (env name)
  (mcase (try-catch `(ok ,(eval (read-from-string name) env))
                    (ex <throwable> `(error ,(exception-message ex))))
    (('ok obj) (mapi (all-definitions obj)
                     (fun (d)
                       `(,(format "~a" d) ,(src-loc>elisp (src-loc d))))))
    (('error msg) `((,name (:error ,msg))))))

(df all-definitions (o)
  (typecase o
    (<gnu.expr.ModuleMethod> (list o))
    (<gnu.expr.GenericProc> (append (mappend all-definitions (gf-methods o))
                                    (let ((s (! get-setter o)))
                                      (if s (all-definitions s) '()))))
    (<java.lang.Class> (list o))
    (<gnu.mapping.Procedure> (all-definitions (! get-class o)))
    ))

(df gf-methods ((f <gnu.expr.GenericProc>))
  (let* ((o :: <obj-ref> (vm-mirror the-vm f))
         (f (! field-by-name (! reference-type o) "methods"))
         (ms (vm-demirror the-vm (! get-value o f))))
    (filter (array-to-list ms) (fun (x) (not (nul? x))))))

(df src-loc (o)
  (typecase o
    (<gnu.expr.ModuleMethod> (module-method>src-loc o))
    (<gnu.expr.GenericProc> `(:error "no src-loc available"))
    (<java.lang.Class> (class>src-loc o))
    ;; XXX handle macros, variables etc.
    ))

(df module-method>src-loc ((f <gnu.expr.ModuleMethod>))
  (! location (module-method>meth-ref f)))

(df module-method>meth-ref ((f <gnu.expr.ModuleMethod>) => <meth-ref>)
  (let ((module (! reference-type
                   (as <obj-ref> (vm-mirror the-vm (@ module f)))))
	(name (mangled-name f)))
    (as <meth-ref> (1st (! methods-by-name module name)))))

(df mangled-name ((f <gnu.expr.ModuleMethod>))
  (let ((name (gnu.expr.Compilation:mangleName (! get-name f))))
    (if (= (! maxArgs f) -1)
        (cat name "$V")
        name)))

(df class>src-loc ((c <java.lang.Class>))
  (1st (! all-line-locations (! reflectedType 
                                (as <com.sun.jdi.ClassObjectReference>
                                    (vm-mirror the-vm c))))))

(df src-loc>elisp ((l <location>))
  (let ((file (! source-path l)) (line (! lineNumber l)))
    (cond ((! starts-with file "(buffer ")
           (mlet (('buffer b 'offset o 'str s) (read-from-string file))
             `(:location (:buffer ,b)
                         (:position ,(+ o (line>offset line s)))
                         nil)))
          (#t
           `(:location ,(or (find-file-in-path file (source-path))
                            (ferror "Can't find source-path: ~s" file))
                       (:line ,line) ())))))

(df ferror (fstring #!rest args)
  (primitive-throw (<java.lang.Error> (to-str (apply format fstring args)))))

;;;;;; class-path hacking

(df find-file-in-path ((filename <str>) (path <list>))
  (let ((f (<file> filename)))
    (cond ((! isAbsolute f) `(:file ,filename))
          (#t (let ((result #f))
                (find-if path (fun (dir) 
                                (let ((x (find-file-in-dir f dir)))
                                  (set result x)))
                         #f)
                result)))))

(df find-file-in-dir ((file <file>) (dir <str>))
  (let ((filename (! getPath file)))
    (or (let ((child (<file> (<file> dir) filename)))
          (and (! exists child)
               `(:file ,(! getPath child))))
        (try-catch 
         (and (not (nul? (! getEntry (<java.util.zip.ZipFile> dir) filename)))
              `(:zip ,dir ,filename))
         (ex <throwable> #f)))))

(define swank-java-source-path
        (let ((jre-home (<java.lang.System>:getProperty "java.home")))
          (list (<file> (<file> jre-home):parent "src.zip"):path)))

(df source-path ()
  (mlet ((base) (search-path-prop "user.dir"))
    (append 
     (list base)
     (map (fun ((s <str>))
             (let ((f (<file> s)))
               (cond ((! isAbsolute f) s)
                     (#t (<file> (as <str> base) s):path))))
          (class-path))
     swank-java-source-path)))

(df class-path ()
  (append (search-path-prop "java.class.path")
          (search-path-prop "sun.boot.class.path")))

(df search-path-prop ((name <str>))
  (array-to-list (! split (java.lang.System:getProperty name)
                    <file>:pathSeparator)))

;;;; Disassemble 

(defslimefun disassemble-symbol (env name)
  (let ((f (eval (read-from-string name) env)))
    (typecase f
      (<gnu.expr.ModuleMethod>
       (let ((mr (module-method>meth-ref f)))
         (call-with-output-string
          (fun (s)
            (parameterize ((current-output-port s))
                          (disassemble-meth-ref mr)))))))))

(df disassemble-meth-ref ((mr <meth-ref>))
  (let* ((t (! declaring-type mr)))
    (format #t "~:[~;static ~]~:[~; final~]~
~:[~;private ~]~:[~;protected ~]~:[~;public ~]~a ~a\n"
            (! is-static mr) (! is-final mr)
            (! is-private mr) (! is-protected mr) (! is-public mr)
            (! name mr) (! signature mr))
    (disassemble (! constant-pool t)
                 (! constant-pool-count t)
                 (! bytecodes mr))))

(df disassemble ((cpool <byte[]>) (cpoolcount <int>) (bytecode <byte[]>))
  (let* ((buffer (<java.io.StringWriter>))
         (out (<java.io.PrintWriter> buffer))
	 (ct (<gnu.bytecode.ClassType> "foo"))
	 (met (! addMethod ct "bar" 0))
	 (ca (<gnu.bytecode.CodeAttr> met))
	 (w (<gnu.bytecode.ClassTypeWriter> ct out 0))
         (constants (let ((s (<java.io.ByteArrayOutputStream>)))
                      (! write s (ash cpoolcount -8))
                      (! write s (logand cpoolcount 255))
                      (! write s cpool)
                      (! toByteArray s))))
    (vm-set-slot the-vm ct 'constants 
                 (<gnu.bytecode.ConstantPool>
                  (<java.io.DataInputStream>
                   (<java.io.ByteArrayInputStream>
                    constants))))
    (! setCode ca bytecode)
    (! disAssemble ca w 0 bytecode:length)
    (! flush out)
    (display (! toString buffer))))

(df test-disas ((c <str>) (m <str>))
  (let* ((vm (as <vm> the-vm))
         (c (as <ref-type> (1st (! classes-by-name vm c))))
         (m (as <meth-ref> (1st (! methods-by-name c m)))))
    (disassemble-meth-ref m)))


;;;; Macroexpansion

(defslimefun swank-macroexpand-1 (env s) (%swank-macroexpand s))
(defslimefun swank-macroexpand (env s) (%swank-macroexpand s))
(defslimefun swank-macroexpand-all (env s) (%swank-macroexpand s))

(df %swank-macroexpand (string)
  (pprint-to-string (%macroexpand (read-from-string string))))

(df %macroexpand (sexp)
  (let* ((lang (<gnu.expr.Language>:getDefaultLanguage))
	 (msgs (<gnu.text.SourceMessages>))
	 (tr (<kawa.lang.Translator> lang msgs)))
    (! pushNewModule tr (as <str> #!null))
    (! parse tr `(lambda () ,sexp))))


;;;; Inspector

(define-simple-class <inspector-state> () 
  (object :init #!null) 
  (parts :: <java.util.ArrayList> :init (<java.util.ArrayList>) )
  (stack :: <list> :init '()))

(df make-inspector (env (vm <vm>) => <chan>)
  (car (spawn/chan (fun (c) (inspector c env vm)))))

(df inspector ((c <chan>) env (vm <vm>))
  (! set-name (current-thread) "inspector")
  (let ((state :: <inspector-state> (<inspector-state>))
        (open #t))
    (while open
      (mcase (recv c)
        (('init str id)
         (set state (<inspector-state>))
         (let ((obj (try-catch (eval (read-from-string str) env)
                               (ex <throwable> ex))))
           (reply c (inspect-object obj state vm) id)))
        (('init-mirror cc id)
         (set state (<inspector-state>))
         (let* ((mirror (recv cc))
                (obj (vm-demirror vm mirror)))
           (reply c (inspect-object obj state vm) id)))
        (('inspect-part n id)
         (let ((part (! get (@ parts state) n)))
           (reply c (inspect-object part state vm) id)))
        (('pop id)
         (reply c (inspector-pop state vm) id))
        (('quit id)
         (reply c 'nil id)
         (set open #f))))))

(df inspect-object (obj (state <inspector-state>) (vm <vm>))
  (set (@ object state) obj)
  (set (@ parts state) (<java.util.ArrayList>))
  (pushf obj (@ stack state))
  (cond ((nul? obj) (list :title "#!null" :id 0 :content `()))
        (#t
         (list :title (pprint-to-string obj) 
               :id (assign-index obj state)
               :content (inspector-content
                         `("class: " (:value ,(! getClass obj)) "\n" 
                           ,@(inspect obj vm))
                         state)))))

(df inspect (obj vm)
  (let* ((obj (as <obj-ref> (vm-mirror vm obj))))
    (packing (pack)
      (typecase obj
        (<array-ref>
         (let ((i 0))
           (iter (! getValues obj)
                 (fun ((v <value>))
                   (pack (format "~d: " i))
                   (set i (1+ i))
                   (pack `(:value ,(vm-demirror vm v)))
                   (pack "\n")))))
        (<obj-ref>
         (let* ((type (! referenceType obj))
                (fields (! allFields type))
                (values (! getValues obj fields)))
           (iter fields 
                 (fun ((f <field>))
                   (let ((val (as <value> (! get values f))))
                     (when (! is-static f)
                       (pack "static "))
                     (pack (! name f)) (pack ": ") 
                     (pack `(:value ,(vm-demirror vm val)))
                     (pack "\n"))))))))))

(df inspector-content (content (state <inspector-state>))
  (map (fun (part)
         (mcase part
           ((':value val)
            `(:value ,(pprint-to-string val) ,(assign-index val state)))
           (x (to-string x))))
       content))

(df assign-index (obj (state <inspector-state>) => <int>)
  (! add (@ parts state) obj)
  (1- (! size  (@ parts state))))

(df inspector-pop ((state <inspector-state>) vm)
  (cond ((<= 2 (len (@ stack state)))
         (let ((obj (cadr (@ stack state))))
           (set (@ stack state) (cddr (@ stack state)))
           (inspect-object obj state vm)))
        (#t 'nil)))

;;;; IO redirection

(define-simple-class <swank-writer> (<java.io.Writer>)
  (c :: <chan>)
  ((*init* (c <chan>)) (set (@ c (this)) c))
  ((write (buffer <char[]>) (from <int>) (to <int>)) :: <void>
   (send c `(write ,(<str> buffer from to))))
  ((close) :: <void>
   (send c 'close))
  ((flush) :: <void>
   (send c 'flush)
   (assert (equal (recv c) 'ok))))

(df swank-writer ((in <chan>))
  (! set-name (current-thread) "redirect thread")
  (let* ((out (as <chan> (recv in)))
         (builder (<builder>))
         (flush (fun ()
                  (unless (zero? (! length builder))
                    (send out `(forward (:write-string ,(<str> builder))))
                    (! setLength builder 0))))
         (closed #f))
    (while (not closed)
      (mcase (recv/timeout (list in)
                           (if (zero? (! length builder)) 30000 300))
        ((_ . ('write str)) 
         (! append builder (as <string> str))
         (when (> (! length builder) 4000)
           (flush)))
        ((c . 'flush) (flush) (send c 'ok))
        ((_ . 'close) (flush) (set closed #t))
        ('timeout 
         ;;(log "timeout: ~d\n" (! length builder))
         (flush)
         (when (not (! isAlive (@ owner (@ peer in))))
           (set closed #t)))))))

(df make-swank-outport ((out <chan>))
  (mlet ((in . _) (spawn/chan swank-writer))
    (send in out)
    (<gnu.mapping.OutPort> (<swank-writer> in) #t #t)))


;;;; Monitor

(df vm-monitor ((c <chan>))
  (! set-name (current-thread) "vm-monitor")
  (let ((vm (vm-attach)))
    ;;(enable-uncaught-exception-events vm)
    (mlet* ((qq (<queue>))
            ((ev . _) (spawn/chan/catch 
                       (fun (c) 
                         (let ((q (! eventQueue vm)))
                           (while #t
                             (iter (! remove q) (fun (e) 
                                                  ;; (log "q: ~s\n" e)
                                                  (! put qq e)))
                             (send c 'vm-event))))))
            (to-string (vm-to-string vm))
            (state (tab)))
      (send c `(publish-vm ,vm))
      (while #t
        (mcase (recv* (list ev c))
          ((_ . ('get-vm cc))
           (send cc vm))
          ((,c . ('debug-info thread from to id))
           (reply c (debug-info thread from to state) id))
          ((,c . ('throw-to-toplevel thread id))
           (set state (throw-to-toplevel thread id c state)))
          ((,c . ('thread-continue thread id))
           (set state (thread-continue thread id c state)))
          ((,c . ('frame-src-loc thread frame id))
           (reply c (frame-src-loc thread frame state) id))
          ((,c . ('frame-locals thread frame id))
           (reply c (frame-locals thread frame state) id))
          ((,c . ('thread-frames thread from to id))
           (reply c (thread-frames thread from to state) id))
          ((,c . ('list-threads id))
           (reply c (list-threads vm state) id))
          ((,c . ('debug-thread ref))
           (set state (debug-thread ref state c)))
          ((,c . ('debug-nth-thread n))
           (let ((t (nth (get state 'all-threads #f) n)))
             ;;(log "thread ~d : ~a\n" n t)
             (set state (debug-thread t state c))))
          ((,ev . 'vm-event)
           (while (not (! isEmpty qq))
             (set state (process-vm-event (! poll qq) c state))))
          ((_ . ('get-exception from tid))
           (mlet ((_ _ es) (get state tid #f))
             (send from (let ((e (car es)))
                          (typecase e 
                            (<exception-event> (! exception e))
                            (<event> e))))))
          ((_ . ('get-local rc tid frame var))
           (send rc (frame-local-var tid frame var state)))
          )))))

(df reply ((c <chan>) value id)
  (send c `(forward (:return (:ok ,value) ,id))))

(df reply-abort ((c <chan>) id)
  (send c `(forward (:return (:abort) ,id))))

(df process-vm-event ((e <event>) (c <chan>) state)
  (log "vm-event: ~s\n" e)
  (typecase e
    (<exception-event>
     (let* ((tref (! thread e))
            (tid (! uniqueID tref))
            (s (get state tid #f)))
       (mcase s
         ('#f
          ;;; XXX redundant in debug-thread
          (let* ((level 1)
                 (state (put state tid (list tref level (list e)))))
            (send c `(forward (:debug ,tid ,level 
                                      ,@(debug-info tid 0 15 state))))
            (send c `(forward (:debug-activate ,tid ,level)))
            state))
         ((_ level exs)
          (send c `(forward (:debug-activate ,(! uniqueID tref) ,level)))
          (put state tid (list tref (1+ level) (cons e exs)))))))
    (<step-event>
     (let* ((r (! request e))
            (k (! get-property r 'continuation)))
       (! disable r)
       (log "k: ~s\n" k)
       (k e))
     state)))

(define-simple-class <listener-abort> (<java.lang.Throwable>)
  ((abort) :: void
   (primitive-throw (this))
   #!void))

(define-simple-class <break-event> (<com.sun.jdi.event.Event>)
  (thread :: <thread-ref>)
  ((*init* (thread :: <thread-ref>)) (set (@ thread (this)) thread))
  ((request) :: <com.sun.jdi.request.EventRequest> #!null)
  ((virtualMachine) :: <vm> (! virtualMachine thread)))

;;;;; Debugger

(df debug-thread ((tref <thread-ref>) state (c <chan>))
  (! suspend tref)
  (let* ((ev (<break-event> tref))
         (id (! uniqueID tref))
         (level 1)
         (state (put state id (list tref level (list ev)))))
    (send c `(forward (:debug ,id ,level ,@(debug-info id 0 10 state))))
    (send c `(forward (:debug-activate ,id ,level)))
    state))

(df debug-info ((tid <int>) (from <int>) to state)
  (mlet ((thread-ref level evs) (get state tid #f))
    (let* ((tref (as <thread-ref> thread-ref))
           (ev (as <event> (car evs)))
           (ex (typecase ev
                 (<exception-event> (! exception ev))
                 (<event> ev)))
           (vm (! virtualMachine tref))
           (desc (typecase ex
                   (<obj-ref> (! toString (vm-demirror vm ex)))
                   (<object> (! toString ex))))
           (type (format "  [type ~a]" 
                         (typecase ex
                           (<obj-ref> (! name (! referenceType ex)))
                           (<object> (!! getName getClass ex)))))
           (bt (thread-frames tid from to state)))
      `((,desc ,type nil) () ,bt ()))))

(df thread-frames ((tid <int>) (from <int>) to state)
  (mlet ((thread level evs) (get state tid #f))
    (let* ((thread (as <thread-ref> thread))
           (fcount (! frameCount thread))
           (stacktrace (event-stacktrace (car evs)))
           (missing (cond ((zero? (@ length stacktrace)) 0)
                          (#t (- (@ length stacktrace) fcount))))
           (fstart (max (- from missing) 0))
           (flen (max (- to from  missing) 0))
           (frames (! frames thread fstart (min flen (- fcount fstart)))))
      (packing (pack)
        (let ((i from))
          (dotimes (_ (max (- missing from) 0))
            (pack (list i (format "~a" 
                                  (! getMethodName (stacktrace i)))))
            (set i (1+ i)))
          (iter frames (fun ((f <frame>))
                         (let ((s (frame-to-string f)))
                           (pack (list i s))
                           (set i (1+ i))))))))))

(df event-stacktrace (ev :: <event> => <java.lang.StackTraceElement[]>)
  (typecase ev
    (<exception-event>
     (! getStackTrace 
        (as <throwable> 
            (vm-demirror (! virtualMachine ev)
                         (! exception ev)))))
    (<event> (<java.lang.StackTraceElement[]>))))

(df frame-to-string ((f <frame>))
  (let ((loc (! location f))
        (vm (! virtualMachine f)))
    (format "~a (~a)" (!! name method loc)
            (call-with-abort 
             (fun () (format "~{~a~^ ~}"
                             (mapi (! getArgumentValues f) 
                                   (fun (arg) 
                                     (pprint-to-string
                                      (vm-demirror vm arg))))))))))

(df frame-src-loc ((tid <int>) (n <int>) state)
  (try-catch 
   (mlet* (((frame vm) (nth-frame tid n state))
           (vm (as <vm> vm)))
     (src-loc>elisp 
      (typecase frame
        (<java.lang.StackTraceElement>
         (let* ((classname (! getClassName frame))
                (classes (! classesByName vm classname))
                (t (as <ref-type> (1st classes))))
           (1st (! locationsOfLine t (! getLineNumber frame)))))
        (<frame> (! location frame)))))
   (ex <throwable> 
       (let ((msg (! getMessage ex)))
         `(:error ,(if (== msg #!null) 
                       (! toString ex)
                       msg))))))

(df nth-frame ((tid <int>) (n <int>) state)
  (mlet ((tref level evs) (get state tid #f))
    (let* ((thread (as <thread-ref> tref))
           (fcount (! frameCount thread))
           (stacktrace (event-stacktrace (car evs)))
           (missing (cond ((zero? (@ length stacktrace)) 0)
                          (#t (- (@ length stacktrace) fcount))))
           (vm (! virtualMachine thread))
           (frame (cond ((< n missing)
                         (stacktrace n))
                        (#t (! frame thread (- n missing))))))
      (list frame vm))))

;;;;; Locals

(df frame-locals ((tid <int>) (n <int>) state)
  (mlet ((thread _ _) (get state tid #f))
    (let* ((thread (as <thread-ref> thread))
           (vm (! virtualMachine thread))
           (p (fun (x) (pprint-to-string (vm-demirror vm x)))))
      (map (fun (x)
             (mlet ((name value) x)
               (list :name name :value (p value) :id 0)))
           (%frame-locals tid n state)))))

(df frame-local-var ((tid <int>) (frame <int>) (var <int>) state => <mirror>)
  (cadr (nth (%frame-locals tid frame state) var)))

(df %frame-locals ((tid <int>) (n <int>) state)
  (mlet ((frame _) (nth-frame tid n state))
    (typecase frame
      (<java.lang.StackTraceElement> '())
      (<frame>
       (let* ((visible (try-catch (! visibleVariables frame)
                                  (ex <com.sun.jdi.AbsentInformationException>
                                      '())))
              (map (! getValues frame visible))
              (self (! thisObject frame))
              (p (fun (x) x)))
         (packing (pack)
           (unless (nul? self)
             (pack (list "this" (p self))))
           (iter (! entrySet map)
                 (fun ((e <java.util.Map$Entry>))
                   (let ((var (as <local-var> (! getKey e)))
                         (val (as <value> (! getValue e))))
                     (pack (list (! name var) (p val))))))))))))

;;;;; Restarts

(df throw-to-toplevel ((tid <int>) (id <int>) (c <chan>) state)
  (mlet ((tref level exc) (get state tid #f))
    (let* ((t (as <thread-ref> tref))
           (ex (<listener-abort>))
           (vm (! virtualMachine t))
           (ex (vm-mirror vm ex))
           (ev (car exc)))
      (typecase ev
        (<exception-event> (log "exc.src-loc: ~s ~s\n" 
                                (! location ev) (! catchLocation ev)))
        (<object> (! stop t ex)) ; XXX race condition?
        )
      (! resume t)
      (reply-abort c id)
      (do ((level level (1- level))
           (exc exc (cdr exc)))
          ((null? exc))
        (send c `(forward (:debug-return ,tid ,level nil))))
      (del state tid))))

(df thread-continue ((tid <int>) (id <int>) (c <chan>) state)
  (mlet ((tref level exc) (get state tid #f))
    (let* ((t (as <thread-ref> tref)))
       (! resume t))
    (reply-abort c id)
    (do ((level level (1- level))
         (exc exc (cdr exc)))
        ((null? exc))
      (send c `(forward (:debug-return ,tid ,level nil))))
    (del state tid)))

(df thread-step ((t <thread-ref>) k)
  (let* ((vm (! virtual-machine t))
         (erm (! eventRequestManager vm))
         (<sr> <com.sun.jdi.request.StepRequest>)
         (req (! createStepRequest erm t <sr>:STEP_MIN <sr>:STEP_OVER)))
    (! setSuspendPolicy req (@ SUSPEND_EVENT_THREAD req))
    (! addCountFilter req 1)
    (! put-property req 'continuation k)
    (! enable req)))

;;;;; Thread stuff

(df list-threads (vm :: <vm> state)
  (let* ((threads (! allThreads vm)))
    (put state 'all-threads threads)
    (packing (pack)
      (iter threads (fun ((t <thread-ref>))
                      (pack (list (! name t)
                                  (let ((s (thread-status t)))
                                    (if (! is-suspended t)
                                        (cat "SUSPENDED/" s)
                                        s))
                                  (! uniqueID t))))))))

(df thread-status (t :: <thread-ref>)
  (let ((s (! status t)))
    (cond ((= s t:THREAD_STATUS_UNKNOWN) "UNKNOWN")
          ((= s t:THREAD_STATUS_ZOMBIE) "ZOMBIE")
          ((= s t:THREAD_STATUS_RUNNING) "RUNNING")
          ((= s t:THREAD_STATUS_SLEEPING) "SLEEPING")
          ((= s t:THREAD_STATUS_MONITOR) "MONITOR")
          ((= s t:THREAD_STATUS_WAIT) "WAIT")
          ((= s t:THREAD_STATUS_NOT_STARTED) "NOT_STARTED")
          (#t "<bug>"))))

;;;;; Bootstrap

(df vm-attach (=> <vm>)
  (attach (getpid) 20))

(df attach (pid timeout)
  (log "attaching: ~a ~a\n" pid timeout)
  (let* ((<ac> <com.sun.jdi.connect.AttachingConnector>)
         (<arg> <com.sun.jdi.connect.Connector$Argument>)
         (vmm (com.sun.jdi.Bootstrap:virtualMachineManager))
         (pa (as <ac>
                 (or 
                  (find-if (! attaching-connectors vmm)
                           (fun (x :: <ac>) 
                             (! equals (! name x) "com.sun.jdi.ProcessAttach"))
                           #f)
                  (error "ProcessAttach connector not found"))))
         (args (! default-arguments pa)))
    (! set-value (as <arg> (! get args (to-str "pid"))) pid)
    (when timeout
      (! set-value (as <arg> (! get args (to-str "timeout"))) timeout))
    (log "attaching2: ~a ~a\n" pa args)
    (! attach pa args)))

(df getpid ()
  (let* ((p (make-process (command-parse "echo -n $PPID") #!null))
         (pid (snarf (! get-input-stream p))))
    (! waitFor p)
    pid))

(df snarf ((in <java.io.InputStream>) => <string>)
  ;; duh..
  (list->string
   (packing (pack) 
     (let loop ()
       (let ((c (! read in)))
         (cond ((= c -1))
               (#t (pack (integer->char c)) (loop))))))))

(df enable-uncaught-exception-events ((vm <vm>))
  (let* ((erm (! eventRequestManager vm))
         (req (! createExceptionRequest erm #!null #f #t)))
    (! setSuspendPolicy req (@ SUSPEND_EVENT_THREAD req))
    (! addThreadFilter req (vm-mirror vm (current-thread)))
    (! enable req)))

(df vm-to-string ((vm <vm>))
  (let* ((obj (as <ref-type> (1st (! classesByName vm "java.lang.Object"))))
         (met (as <meth-ref> (1st (! methodsByName obj "toString")))))
    (fun ((o <obj-ref>) (t <thread-ref>)) 
      (! value
         (as <str-ref>
             (! invokeMethod o t met '() 
                (<obj-ref>:.INVOKE_SINGLE_THREADED)))))))

(define-simple-class <swank-global-variable> ()
  (var :allocation 'static)
  ((getValue) :allocation 'static var)
  ((setValue value) :allocation 'static (set var value)))

(df vm-mirror ((vm <vm>) obj)
  (synchronized vm
    (<swank-global-variable>:setValue #!null) ; prepare class
    (let* ((c (as <ref-type>
                  (1st (! classes-by-name vm "swank$Mnglobal$Mnvariable"))))
           (f (! fieldByName c "var")))
    (<swank-global-variable>:setValue obj)
    (! getValue c f))))

(df vm-demirror ((vm <vm>) (v <value>))
  (synchronized vm
    (if (== v #!null) 
      #!null
      (typecase v
        (<obj-ref>
         (<swank-global-variable>:setValue #!null) ; prepare class
         (let* ((c (as <com.sun.jdi.ClassType>
                       (1st
                        (! classes-by-name vm "swank$Mnglobal$Mnvariable"))))
                (f (! fieldByName c "var")))
           (! setValue c f v)
           (<swank-global-variable>:getValue)))
        (<com.sun.jdi.IntegerValue> (! value v))
        (<com.sun.jdi.LongValue> (! value v))
        (<com.sun.jdi.CharValue> (! value v))
        (<com.sun.jdi.ByteValue> (! value v))
        (<com.sun.jdi.BooleanValue> (! value v))
        (<com.sun.jdi.ShortValue> (! value v))
        (<com.sun.jdi.FloatValue> (! value v))
        (<com.sun.jdi.DoubleValue> (! value v))))))

(df vm-set-slot ((vm <vm>) (o <object>) (name <str>) value)
  (let* ((o (as <obj-ref> (vm-mirror vm o)))
         (t (! reference-type o))
	 (f (! field-by-name t name)))
    (! set-value o f (vm-mirror vm value))))

(define-simple-class <ucex-handler>
    (<java.lang.Thread$UncaughtExceptionHandler>)
  (fn :: <gnu.mapping.Procedure>)
  ((*init* (fn :: <gnu.mapping.Procedure>)) (set (@ fn (this)) fn))
  ((uncaughtException (t <thread>) (e <throwable>))
   :: <void>
   ;;(! println (java.lang.System:.err) (to-str "uhexc:::"))
   (! apply2 fn t e)
    #!void))

;;;; Channels

(df spawn (f)
  (let ((thread (<java.lang.Thread> (%runnable f))))
    (! start thread)
    thread))

(df %%runnable (f => <java.lang.Runnable>) 
  (<runnable> f)
  ;;(<gnu.mapping.RunnableClosure> f)
  )

(df %runnable (f => <java.lang.Runnable>)
  (<runnable>
   (fun ()
     (try-catch (f)
                (ex <throwable> 
                    (log "exception in thread ~s: ~s" (current-thread)
                          ex)
                    (! printStackTrace ex))))))

(df chan () 
  (let ((lock (<object>))
        (im (<chan>))
        (ex (<chan>)))
    (set (@ lock im) lock)
    (set (@ lock ex) lock)
    (set (@ peer im) ex)
    (set (@ peer ex) im)
    (cons im ex)))

(df immutable? (obj)
  (or (== obj #!null)
      (symbol? obj)
      (number? obj)
      (char? obj)
      (instance? obj <str>)
      (null? obj)))

(df send ((c <chan>) value => <void>)
  (df pass (obj)
    (cond ((immutable? obj)
           obj)
          ((string? obj) (! to-string obj))
          ((pair? obj)
           (let loop ((r (list (pass (car obj))))
                      (o (cdr obj)))
             (cond ((null? o) (reverse! r))
                   ((pair? o) (loop (cons (pass (car o)) r) (cdr o)))
                   (#t (append (reverse! r) (pass o))))))
          ((instance? obj <chan>)
           (let ((o :: <chan> obj))
             (assert (== (@ owner o) (current-thread)))
             (synchronized (@ lock c)
               (set (@ owner o) (@ owner (@ peer c))))
             o))
          ((or (instance? obj <env>)
               (instance? obj <mirror>))
           ;; those can be shared, for pragramatic reasons
           obj
           )
          (#t (error "can't send" obj (class-name-sans-package obj)))))
  ;;(log "send: ~s ~s -> ~s\n" value (@ owner c) (@ owner (@ peer c)))
  (assert (== (@ owner c) (current-thread)))
  (synchronized (@ owner (@ peer c))
    (! put (@ queue (@ peer c)) (pass value))
    (! notify (@ owner (@ peer c)))))

(df recv ((c <chan>))
  (cdr (recv/timeout (list c) 0)))

(df recv* ((cs <iterable>))
  (recv/timeout cs 0))

(df recv/timeout ((cs <iterable>) (timeout <long>))
  (let ((self (current-thread))
        (end (if (zero? timeout) 
                 0 
                 (+ (current-time) timeout))))
    (synchronized self
      (let loop ()
        (let ((ready (find-if cs 
                              (fun ((c <chan>))
                                (not (! is-empty (@ queue c))))
                              #f)))
          (cond (ready (cons ready (! take (@ queue (as <chan> ready)))))
                ((zero? timeout)
                 (! wait self) (loop))
                (#t 
                 (let ((now (current-time)))
                   (cond ((<= end now)
                          'timeout)
                         (#t
                          (! wait self (- end now))
                          (loop)))))))))))

(df rpc ((c <chan>) msg)
  (mlet* (((im . ex) (chan))
          ((op . args) msg))
    (send c `(,op ,ex . ,args))
    (recv im)))

(df spawn/chan (f)
  (mlet ((im . ex) (chan))
    (let ((thread (<java.lang.Thread> (%%runnable (fun () (f ex))))))
      (set (@ owner ex) thread)
      (! start thread)
      (cons im thread))))

(df spawn/chan/catch (f)
  (spawn/chan 
   (fun (c)
     (try-catch 
      (f c)
      (ex <throwable> 
          (send c `(error ,(! toString ex)
                          ,(class-name-sans-package ex))))))))

(define-simple-class <runnable> (<java.lang.Runnable>)
  (fn :: <gnu.mapping.Procedure>)
  ((*init* (fn <gnu.mapping.Procedure>)) (set (@ fn (this)) fn))
  ((run) :: void
   (! apply0 fn)
   #!void))

;;;; Logging

(define swank-log-port (current-error-port))
(df log (fstr #!rest args)
  (synchronized swank-log-port
    (apply format swank-log-port fstr args)
    (force-output swank-log-port))
  #!void
  )

;;;; Random helpers

(df 1+ (x) (+ x 1))
(df 1- (x) (- x 1))

(df len (x => <int>)
  (typecase x
    (<list> (length x))
    (<string> (string-length x))
    (<vector> (vector-length x))
    (<str> (! length x))
    (<java.util.List> (! size x))))

(df put (tab key value) (hash-table-set! tab key value) tab)
(df get (tab key default) (hash-table-ref/default tab key default))
(df del (tab key) (hash-table-delete! tab key) tab)
(df tab () (make-hash-table))

(df equal (x y => <boolean>) (equal? x y))

(df current-thread (=> <thread>) (java.lang.Thread:currentThread))
(df current-time (=> <long>) (java.lang.System:currentTimeMillis))

(df nul? (x) (== x #!null))

(df read-from-string (str)
  (call-with-input-string str read))

;;(df print-to-string (obj) (call-with-output-string (fun (p) (write obj p))))
   
(df pprint-to-string (obj)
  (let* ((w (<java.io.StringWriter>))
         (p (<gnu.mapping.OutPort> w #t #f)))
    (try-catch (write obj p)
               (ex <throwable> 
                   (format p "#<error while printing ~a ~a>" 
                           ex (class-name-sans-package ex))))
    (! flush p)
    (to-string (! getBuffer w))))

(define cat string-append)

(df values-to-list (values)
  (cond ((instance? values <gnu.mapping.Values>)
         (array-to-list (gnu.mapping.Values:getValues values)))
        (#t (list values))))

(df array-to-list ((array <java.lang.Object[]>) => <list>)
  (packing (pack)
    (dotimes (i (@ length array))
      (pack (array i)))))

(df lisp-bool (obj)
  (cond ((== obj 'nil) #f)
        ((== obj 't) #t)
        (#t (error "Can't map lisp boolean" obj))))

(df path-sans-extension ((p path) => <string>)
  (let ((ex (! get-extension p))
        (str (! to-string p)))
    (to-string (cond ((not ex) str)
                     (#t (! substring str 0 (- (len str) (len ex) 1)))))))

(df class-name-sans-package ((obj <object>))
  (cond ((nul? obj) "<#!null>")
        (#t
         (let* ((c (! get-class obj)) (n (! get-simple-name c)))
           (cond ((equal n "") (! get-name c))
                 (#t n))))))

(df list-env ((env <env>))
  (let* (;;(env (gnu.mapping.Environment:current))
         (enum (! enumerateAllLocations env)))
    (packing (pack)
      (while (! hasMoreElements enum)
        (pack (! nextLocation enum))))))

(df list-file (filename)
  (with (port (call-with-input-file filename))
    (let* ((lang (gnu.expr.Language:getDefaultLanguage))
           (messages (<gnu.text.SourceMessages>))
           (comp (! parse lang port messages 0)))
      (! get-module comp))))

(df list-decls (file)
  (let* ((module (as <gnu.expr.ModuleExp> (list-file file))))
    (do ((decl :: <gnu.expr.Declaration>
               (! firstDecl module) (! nextDecl decl)))
        ((nul? decl))
      (format #t "~a ~a:~d:~d\n" decl
              (! getFileName decl)
              (! getLineNumber decl)
              (! getColumnNumber decl)
              ))))

(df %time (fn)
  (define-alias <mf> <java.lang.management.ManagementFactory>)
  (define-alias <gc> <java.lang.management.GarbageCollectorMXBean>)
  (let* ((gcs (<mf>:getGarbageCollectorMXBeans))
         (mem (<mf>:getMemoryMXBean))
         (jit (<mf>:getCompilationMXBean))
         (oldjit (! getTotalCompilationTime jit))
         (oldgc (packing (pack)
                  (iter gcs (fun ((gc <gc>))
                              (pack (cons gc 
                                          (list (! getCollectionCount gc)
                                                (! getCollectionTime gc))))))))
         (heap (!! getUsed getHeapMemoryUsage mem))
         (nonheap (!! getUsed getNonHeapMemoryUsage mem))
         (start (java.lang.System:nanoTime))
         (values (fn))
         (end (java.lang.System:nanoTime))
         (newheap (!! getUsed getHeapMemoryUsage mem))
         (newnonheap (!! getUsed getNonHeapMemoryUsage mem)))
    (format #t "~&")
    (let ((njit (! getTotalCompilationTime jit)))
      (format #t "; JIT compilation: ~:d ms (~:d)\n" (- njit oldjit) njit))
    (iter gcs (fun ((gc <gc>))
                (mlet ((_ count time) (assoc gc oldgc))
                  (format #t "; GC ~a: ~:d ms (~d)\n"
                          (! getName gc)
                          (- (! getCollectionTime gc) time)
                          (- (! getCollectionCount gc) count)))))
    (format #t "; Heap: ~@:d (~:d)\n" (- newheap heap) newheap)
    (format #t "; Non-Heap: ~@:d (~:d)\n" (- newnonheap nonheap) newnonheap)
    (format #t "; Elapsed time: ~:d us\n" (/ (- end start) 1000))
    values))

(define-syntax time
  (syntax-rules ()
    ((time form)
     (%time (lambda () form)))))

(df gc ()
  (let* ((mem (java.lang.management.ManagementFactory:getMemoryMXBean))
         (oheap (!! getUsed getHeapMemoryUsage mem))
         (onheap (!! getUsed getNonHeapMemoryUsage mem))
         (_ (! gc mem))
         (heap (!! getUsed  getHeapMemoryUsage mem))
         (nheap (!! getUsed getNonHeapMemoryUsage mem)))
    (format #t "; heap: ~@:d (~:d) non-heap: ~@:d (~:d)\n"
             (- heap oheap) heap (- onheap nheap) nheap)))

(df room ()
  (let* ((pools (java.lang.management.ManagementFactory:getMemoryPoolMXBeans))
         (mem (java.lang.management.ManagementFactory:getMemoryMXBean))
         (heap (!! getUsed  getHeapMemoryUsage mem))
         (nheap (!! getUsed getNonHeapMemoryUsage mem)))
    (iter pools (fun ((p <java.lang.management.MemoryPoolMXBean>))
                  (format #t "~&; ~a~1,16t: ~10:d\n"
                          (! getName p)
                          (!! getUsed getUsage p))))
    (format #t "; Heap~1,16t: ~10:d\n" heap)
    (format #t "; Non-Heap~1,16t: ~10:d\n" nheap)))

(df javap (class #!key method)
  (let* ((<is> <java.io.ByteArrayInputStream>)
         (bytes
          (typecase class
            (<string> (read-bytes (<java.io.FileInputStream> (to-str class))))
            (<byte[]> class)
            (<symbol> (read-class-file class))))
         (cdata (<sun.tools.javap.ClassData> (<is> bytes)))
         (p (<sun.tools.javap.JavapPrinter> 
	     (<is> bytes)
             (current-output-port)
             (<sun.tools.javap.JavapEnvironment>))))
    (cond (method
           (dolist ((m <sun.tools.javap.MethodData>)
                    (array-to-list (! getMethods cdata)))
             (when (equal method (! getName m))
               (! printMethodSignature p m (! getAccess m))
               (! printExceptions p m)
               (newline)
               (! printVerboseHeader p m)
               (! printcodeSequence p m))))
          (#t (p:print)))
    (values)))

(df read-bytes ((is <java.io.InputStream>) => <byte[]>)
  (let ((os (<java.io.ByteArrayOutputStream>)))
    (let loop ()
      (let ((c (! read is)))
        (cond ((= c -1))
              (#t (! write os c) (loop)))))
    (! to-byte-array os)))

(df read-class-file ((name <symbol>) => <byte[]>)
  (let ((f (cat (! replace (to-str name) (as <char> #\.) (as <char> #\/)) 
                ".class")))
    (mcase (find-file-in-path f (class-path))
      ('#f (ferror "Can't find classfile for ~s" name))
      ((:zip zipfile entry)
       (let* ((z (<java.util.zip.ZipFile> (as <str> zipfile)))
              (e (z:getEntry (as <str> entry))))
         (read-bytes (z:getInputStream e))))
      ((:file s) (read-bytes (<java.io.FileInputStream> (as <str> s)))))))

(df all-instances ((vm <vm>) (classname <str>))
  (mappend (fun ((c <class-ref>)) (to-list (! instances c 9999)))
	   (%all-subclasses vm classname)))

(df %all-subclasses ((vm <vm>) (classname <str>))
  (mappend (fun ((c <class-ref>)) (cons c (to-list (! subclasses c))))
           (to-list (! classes-by-name vm classname))))

(df find-if ((i <iterable>) test default)
  (let ((iter (! iterator i))
        (found #f))
    (while (and (not found) (! has-next iter))
      (let ((e (! next iter)))
        (when (test e)
          (set found #t)
          (set default e))))
    default))

(df filter ((i <iterable>) test)
  (packing (pack)
    (for ((e i))
      (when (test e)
        (pack e)))))

(df iter ((i <iterable>) fun)
  (let ((iter (! iterator i)))
    (while (! has-next iter)
      (fun (! next iter)))))

(df mapi ((i <iterable>) f)
  (packing (pack) (iter i (fun (e) (pack (f e))))))

(df nth ((i <iterable>) (n <int>))
  (let ((iter (! iterator i)))
    (while (> n 0)
      (! next iter)
      (set n (1- n)))
    (! next iter)))

(df 1st ((i <iterable>)) (!! next iterator i))

(df to-list ((i <iterable>))
  (packing (pack) (iter i pack)))

(df as-list ((o <java.lang.Object[]>) => <java.util.List>)
  (java.util.Arrays:asList o))

(df mappend (f list)
  (apply append (map f list)))

(df to-string (obj => <string>)
  (cond ((instance? obj <str>) (<gnu.lists.FString> (as <str> obj)))
        ((string? obj) obj)
        ((symbol? obj) (symbol->string obj))
        ((instance? obj <java.lang.StringBuffer>)
         (<gnu.lists.FString> (as <java.lang.StringBuffer> obj)))
        ((instance? obj <java.lang.StringBuilder>)
         (<gnu.lists.FString> (as <java.lang.StringBuilder> obj)))
        (#t (error "Not a string designator" obj 
                   (class-name-sans-package obj)))))

(df to-str (obj => <str>)
  (cond ((string? obj) (! toString obj))
        ((symbol? obj) (! getName (as <gnu.mapping.Symbol> obj)))
        ((instance? obj <str>) obj)
        (#t (error "Not a string designator" obj
                   (class-name-sans-package obj)))))

;; Local Variables:
;; mode: goo 
;; compile-command:"kawa -e '(compile-file \"swank-kawa.scm\"\"swank-kawa\")'" 
;; End: