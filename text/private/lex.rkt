#lang racket/base
(require parser-tools/lex
         (prefix-in : parser-tools/lex-sre)
         (for-syntax racket/base))

(provide lex
         lex-all

         ;; From `parser-tools/lex`
         token-name
         token-value
         ;; Our additions:
         token-e
         token-line)

(define-tokens non-terminals (identifier
                              number
                              literal
                              comment
                              whitespace

                              operator
                              block-operator
                              more-operator
                              alt-operator
                              continue-operator

                              opener closer
                              comma-operator
                              semicolon-operator
                              EOF))

(define stx-for-original-property (read-syntax #f (open-input-string "original")))

(define-syntax (token stx)
  (syntax-case stx ()
    [(_ name val)
     (identifier? (syntax name))
     (let ([name (syntax name)])
       (with-syntax ([token-name (datum->syntax
                                  name
                                  (string->symbol
                                   (format "token-~a" (syntax-e name))))]
                     [source-name (datum->syntax name 'source-name)]
                     [start-pos (datum->syntax name 'start-pos)]
                     [end-pos (datum->syntax name 'end-pos)])
         (syntax 
          (token-name 
           (datum->syntax #f val
                                 (list
                                  source-name
                                  (position-line start-pos)
                                  (position-col start-pos)
                                  (position-offset start-pos)
                                  (- (position-offset end-pos)
                                     (position-offset start-pos)))
                                 stx-for-original-property)))))]))
(define-syntax (ttoken stx)
  (syntax-case stx ()
    [(_ name)
     (identifier? (syntax name))
     (syntax (token name 'name))]))

(define-lex-abbrev symbolic
  ;; Note: no "\" or "#"
  (:or "=" "!" "@" "$" "%" "^" "&" "*" "-" "+" "<" ">" "." "?" "/" "~" "'" "`"))

(define (lex source-name)
  (lexer
   [(eof) (ttoken EOF)]
   [":"
    (token block-operator (string->symbol lexeme))]
   ["&"
    (token more-operator (string->symbol lexeme))]
   [#\| (token alt-operator '\|)]
   [#\\ (token continue-operator '|\|)]
   [(:- (:+ symbolic) #\| #\& #\: "//" "/*" "*/")
    (token operator (string->symbol lexeme))]
   [(:: #\"
        (:* (:~ #\"))
        #\")
    (token literal lexeme)]
   [(:: "#" (:or "true" "false"))
    (token literal (if (equal? lexeme "#true")
                       #t
                       #f))]
   [(:: (:or alphabetic #\_)
        (:* (:or alphabetic
                 numeric
                 #\_)))
    (token identifier (string->symbol lexeme))]
   [(:: (char-range #\0 #\9)
        (:* (char-range #\0 #\9))
        (:? (:: #\.
                (:* (char-range #\0 #\9)))))
    (token number (string->number lexeme))]
   [(:or #\( #\[ #\{) (token opener lexeme)]
   [(:or #\) #\] #\}) (token closer lexeme)]
   [(:or #\,) (token comma-operator (string->symbol lexeme))]
   [(:or #\;) (token semicolon-operator (string->symbol lexeme))]
   [(:: #\/ #\/ (:* (:~ #\newline))) (token comment lexeme)]
   [(:: "/*" (complement (:: any-string "*/" any-string)) "*/") (token comment lexeme)]
   [(:+ whitespace) (token whitespace lexeme)]))

(define (lex-all in)
  (port-count-lines! in)
  (let ([lex (lex (object-name in))])
    (let loop ()
      (define v (lex in))
      (if (eq? 'EOF (token-name v))
          null
          (cons v (loop))))))

(define (token-line t)
  (syntax-line (token-value t)))

(define (token-e t)
  (syntax-e (token-value t)))
