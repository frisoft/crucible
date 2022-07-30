(set-option :print-success true)
; success
(set-option :produce-models true)
; success
(set-option :global-declarations true)
; success
(set-option :produce-abducts true)
; success
(set-logic ALL)
; success
(get-info :error-behavior)
; (:error-behavior immediate-exit)
(push 1)
; success
(push 1)
; success
; ./cFiles32bit/test-multinv-32.c:7:3
(declare-fun y () (_ BitVec 32))
; success
(define-fun x!0 () (_ BitVec 64) (concat (ite (= ((_ extract 31 31) y) (_ bv1 1)) (_ bv4294967295 32) (_ bv0 32)) y))
; success
(declare-fun x () (_ BitVec 32))
; success
(define-fun x!1 () (_ BitVec 64) (concat (ite (= ((_ extract 31 31) x) (_ bv1 1)) (_ bv4294967295 32) (_ bv0 32)) x))
; success
(define-fun x!2 () (_ BitVec 64) (bvmul x!0 x!1))
; success
(define-fun x!3 () (_ BitVec 32) (bvmul x y))
; success
(define-fun x!4 () (_ BitVec 64) (concat (ite (= ((_ extract 31 31) x!3) (_ bv1 1)) (_ bv4294967295 32) (_ bv0 32)) x!3))
; success
(define-fun x!5 () Bool (= x!2 x!4))
; success
(define-fun x!6 () Bool (not x!5))
; success
(assert (! x!6 :named x!7))
; success
(check-sat)
; sat
(get-value (x))
; ((x #b01011111111111111111111111111111))
(get-value (y))
; ((y #b10000000000000000000000000000001))
(get-abduct abd x!5 )
