#lang racket/base
(require racket/pretty
         "private/lex.rkt")

;; See "indent.rkt" for some overall notes

;; Parsing state at the group level:
(struct state (line          ; current group's line
               in-parens?    ; immediately in "(...)" or "[...]"?
               after-bar?))  ; after | in group?

;; Parsing state at the group-sequence level for top and parens:
(struct group-state (closer       ; expected closer, a string or EOF
                     in-parens?)) ; immediately in "(...)" or "[...]"?

;; Parsing state at the group-sequence level for "|" and "=>":
(struct nested-group-state (line         ; next group's line
                            after-bar?)) ; after | in an enclodinig group?

;; Report an error on failure, but then keep parsing anyway
(define (fail msg)
  (log-error msg))

;; Parse all groups in a stream
(define (parse-top-groups l)
  (define-values (gs rest-l end-line)
    (parse-groups l (group-state eof #f)))
  (unless (null? rest-l)
    (error "had leftover items" rest-l))
  (datum->syntax #f `(#%all ,@gs)))

;; Parse a sequence of groups, top level or in opener-closer,
;;   consuming the closer.
;; Returns: the list of groups
;;          remaining tokens after a closer
;;          closer's line
(define (parse-groups l sg)
  (cond
    [(null? l)
     (define closer (group-state-closer sg))
     (unless (eof-object? closer)
       (fail (format "expected ~s" closer)))
     (values null null #f)]
    [else
     (define t (car l))
     (case (token-name t)
       [(closer)
        (define closer (group-state-closer sg))
        (unless (equal? closer (token-e t))
          (fail (format "expected ~s; closing at ~a" closer (token-value t))))
        (if (eof-object? closer)
            ;; continue afte extra closer:
            (parse-groups l sg)
            ;; stop at closer
            (values null (cdr l) (token-line t)))]
       [(comma-operator)
        (define-values (gs rest-l end-line)
          (parse-groups (cdr l) sg))
        (values (cons (token-value t) gs)
                rest-l
                end-line)]
       [(semicolon-operator) (parse-groups (cdr l) sg)]
       [(whitespace comment) (parse-groups (cdr l) sg)]
       [else
        (define-values (g rest-l group-end-line) 
          (parse-group l (state (token-line (car l))
                                (group-state-in-parens? sg)
                                #f)))
        (define-values (gs rest-rest-l end-line)
          (parse-groups rest-l sg))
        (values (if (null? g)
                    gs
                    (cons (cons '#%grp g) gs))
                rest-rest-l
                end-line)])]))

;; Parse a sequence of groups under "|" or "=>".
;; Returns: the list of groups
;;          remaining tokens after sequence
;;          ending line
(define (parse-nested-groups l nsg)
  (define (done)
    (values null l (nested-group-state-line nsg)))
  (cond
    [(null? l)
     (done)]
    [else
     (define t (car l))
     (define line (token-line t))
     (define (keep-group #:after-bar? [after-bar? (nested-group-state-after-bar? nsg)])
       (define-values (g rest-l end-line)
         (parse-group l (state (token-line (car l))
                               #f
                               after-bar?)))
       (define-values (gs rest-rest-l nested-end-line)
         (parse-nested-groups rest-l (struct-copy nested-group-state nsg
                                                  [line end-line])))
       (values (cons (cons '#%grp g) gs)
               rest-rest-l
               nested-end-line))
     (cond
       [(line . > . (add1 (nested-group-state-line nsg)))
        (done)]
       [else
        (case (token-name t)
          [(closer comma-operator semicolon-operator)
           (done)]
          [(whitespace comment)
           (parse-nested-groups (cdr l) (struct-copy nested-group-state nsg
                                                     [line line]))]
          [(bar-operator)
           (if (nested-group-state-after-bar? nsg)
               (done)
               (keep-group #:after-bar? #t))]
          [else
           (keep-group)])])]))

;; Parse one group.
;; Returns: the list of items in the group
;;          remaining tokens after group
;;          ending line
(define (parse-group l s)
  (define (done)
    (values null l (state-line s)))
  (cond
    [(null? l) (done)]
    [else
     (define t (car l))
     (define line (token-line t))
     (define (keep)
       (define-values (g rest-l end-line)
         (parse-group (cdr l) (struct-copy state s [line line])))
       (values (cons (token-value t) g) rest-l end-line))
     (define new-group? (line . > . (add1 (state-line s))))
     (cond
       [new-group?
        (done)]
       [else
        (define new-line? (line . > . (state-line s)))
        (define (keep-nested-group #:inline? inline?
                                   #:after-bar? after-bar?)
          (define next-line (next-line-of (cdr l)))
          (define-values (gs rest-l nested-end-line)
            (parse-nested-groups (cdr l)
                                 (nested-group-state (or next-line
                                                         line)
                                                     after-bar?)))
          (define-values (g rest-rest-l end-line)
            (parse-group rest-l (struct-copy state s
                                             [line nested-end-line])))
          (values (cons (token-value t)
                        ;; Not sure the `inline?` distinction is a good idea
                        (if (and inline?
                                 (pair? gs))
                            (append gs
                                    g)
                            (cons (cons '#%grp gs)
                                  g)))
                  rest-rest-l
                  end-line))
        (case (token-name (car l))
          [(identifier number keyword literal)
           (if new-line?
               (done)
               (keep))]
          [(operator)
           (cond
             [new-line?
              (if (state-in-parens? s)
                  (keep)
                  (done))]
             [else
              (keep)])]
          [(colon-operator)
           (cond
             [new-line?
              (keep)]
             [else
              (keep)])]
          [(bs-operator)
           (cond
             [new-line?
              (parse-group (cdr l) s)]
             [else
              (define next-line (next-line-of (cdr l)))
              (if (and next-line
                       (= next-line (add1 line)))
                  (parse-group (cdr l) (struct-copy state s
                                                    [line next-line]))
                  (parse-group (cdr l) s))])]
          [(opener)
           (cond
             [new-line?
              (done)]
             [else
              (define-values (closer in-parens? tag)
                (case (token-e t)
                  [("(") (values ")" #t '#%paren)]
                  [("[") (values "]" #t '#%bracket)]
                  [("{") (values "}" #f '#%grp)]
                  [else (error "unknown opener" t)]))
              (define-values (gs rest-l close-line)
                (parse-groups (cdr l)
                              (group-state closer in-parens?)))
              (define-values (g rest-rest-l end-line)
                (parse-group rest-l (struct-copy state s
                                                 [line close-line])))
              (values (cons (cons tag gs)
                            g)
                      rest-rest-l
                      end-line)])]
          [(closer comma-operator semicolon-operator)
           (done)]
          [(arrow-operator)
           (keep-nested-group #:inline? #f
                              #:after-bar? (state-after-bar? s))]
          [(bar-operator)
           (cond
             [(state-after-bar? s)
              (done)]
             [else
              (keep-nested-group #:inline? #t
                                 #:after-bar? #t)])]
          [(whitespace comment)
           (parse-group (cdr l) s)]
          [else
           (error "unexpected" t)])])]))

;; Lookahead
(define (next-line-of l)
  (cond
    [(null? l) #f]
    [else
     (case (token-name (car l))
       [(whitespace comment) (next-line-of (cdr l))]
       [else
        (token-line (car l))])]))

(define (parse-all in)
  (define l (lex-all in))
  (unless (null? l)
    (pretty-write
     (syntax->datum (parse-top-groups l)))))
  
(module+ main
  (require racket/cmdline)

  (command-line
   #:args file
   (if (null? file)
       (parse-all (current-input-port))
       (for-each (lambda (file)
                   (call-with-input-file*
                    file
                    parse-all))
                 file))))