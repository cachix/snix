;;; ex-sclf.lisp --- subset of sclf used by mime4cl

;;;  Copyright (C) 2005-2010 by Walter C. Pelissero
;;;  Copyright (C) 2022-2023 The TVL Authors

;;;  Author: sternenseemann <sternenseemann@systemli.org>
;;;  Project: mime4cl
;;;
;;;  mime4cl uses sclf for miscellaneous utility functions. sclf's portability
;;;  is quite limited. Since mime4cl is the only thing in TVL's depot depending
;;;  on sclf, it made more sense to strip down sclf to the extent mime4cl needed
;;;  in order to lessen the burden of porting it to other CL implementations
;;;  later.
;;;
;;;  Eventually it probably makes sense to drop the utilities we don't like and
;;;  merge the ones we do like into depot's own utility package, klatre.

#+cmu (ext:file-comment "$Module: ex-sclf.lisp $")

;;; This library is free software; you can redistribute it and/or
;;; modify it under the terms of the GNU Lesser General Public License
;;; as published by the Free Software Foundation; either version 2.1
;;; of the License, or (at your option) any later version.
;;; This library is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;; Lesser General Public License for more details.
;;; You should have received a copy of the GNU Lesser General Public
;;; License along with this library; if not, write to the Free
;;; Software Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
;;; 02111-1307 USA

(defpackage :mime4cl-ex-sclf
  (:use :common-lisp)

  (:export
   #:aif
   #:awhen
   #:aand
   #:it

   #:gcase

   #:with-gensyms

   #:split-at
   #:split-string-at-char
   #:+whitespace+
   #:whitespace-p
   #:string-concat
   #:s+
   #:string-starts-with
   #:string-trim-whitespace
   #:string-left-trim-whitespace
   #:string-right-trim-whitespace

   #:queue
   #:make-queue
   #:queue-append
   #:queue-pop
   #:queue-empty-p

   #:save-file-excursion
   #:read-file

   #:promise
   #:make-promise
   #:lazy
   #:force
   #:forced-p
   #:deflazy

   #:f++

   #:week-day->string
   #:month->string))

(in-package :mime4cl-ex-sclf)

;; MACRO UTILS

(defmacro with-gensyms ((&rest symbols) &body body)
  "Gensym all SYMBOLS and make them available in BODY.
See also LET-GENSYMS."
  `(let ,(mapcar #'(lambda (s)
                     (list s '(gensym))) symbols)
     ,@body))

;; CONTROL FLOW

(defmacro aif (test then &optional else)
  `(let ((it ,test))
     (if it
         ,then
         ,else)))

(defmacro awhen (test &body then)
  `(let ((it ,test))
     (when it
       ,@then)))

(defmacro aand (&rest args)
  (cond ((null args) t)
        ((null (cdr args)) (car args))
        (t `(aif ,(car args) (aand ,@(cdr args))))))

(defmacro gcase ((value &optional (test 'equalp)) &rest cases)
  "Generic CASE macro.  Match VALUE to CASES as if by the normal CASE
but use TEST as the comparison function, which defaults to EQUALP."
  (with-gensyms (val)
    `(let ((,val ,value))
       ,(cons 'cond
              (mapcar #'(lambda (case-desc)
                          (destructuring-bind (vals &rest forms) case-desc
                            `(,(cond ((consp vals)
                                      (cons 'or (mapcar #'(lambda (v)
                                                            (list test val v))
                                                        vals)))
                                     ((or (eq vals 'otherwise)
                                          (eq vals t))
                                      t)
                                     (t (list test val vals)))
                               ,@forms)))
                      cases)))))

;; SEQUENCES

(defun position-any (bag sequence &rest position-args)
  "Find any element of bag in sequence and return its position.
Accept any argument accepted by the POSITION function."
  (apply #'position-if #'(lambda (element)
                           (find element bag)) sequence position-args))

(defun split-at (bag sequence &key (start 0) key)
  "Split SEQUENCE at occurence of any element from BAG.
Contiguous occurences of elements from BAG are considered atomic;
so no empty sequence is returned."
  (let ((len (length sequence)))
    (labels ((split-from (start)
               (unless (>= start len)
                 (let ((sep (position-any bag sequence :start start :key key)))
                   (cond ((not sep)
                          (list (subseq sequence start)))
                         ((> sep start)
                          (cons (subseq sequence start sep)
                                (split-from (1+ sep))))
                         (t
                          (split-from (1+ start))))))))
      (split-from start))))

;; STRINGS

(defvar +whitespace+ '(#\return #\newline #\tab #\space #\page))

(defun whitespace-p (char)
  (member char +whitespace+))

(defun string-trim-whitespace (string)
  (string-trim +whitespace+ string))

(defun string-right-trim-whitespace (string)
  (string-right-trim +whitespace+ string))

(defun string-left-trim-whitespace (string)
  (string-left-trim +whitespace+ string))

(defun split-string-at-char (string separator &key escape skip-empty)
  "Split STRING at SEPARATORs and return a list of the substrings.  If
SKIP-EMPTY is true then filter out the empty substrings.  If ESCAPE is
not nil then split at SEPARATOR only if it's not preceded by ESCAPE."
  (declare (type string string) (type character separator))
  (labels ((next-separator (beg)
             (let ((pos (position separator string :start beg)))
               (if (and escape
                        pos
                        (plusp pos)
                        (char= escape (char string (1- pos))))
                   (next-separator (1+ pos))
                   pos)))
           (parse (beg)
             (cond ((< beg (length string))
                    (let* ((end (next-separator beg))
                           (substring (subseq string beg end)))
                      (cond ((and skip-empty (string= "" substring))
                             (parse (1+ end)))
                            ((not end)
                             (list substring))
                            (t
                             (cons substring (parse (1+ end)))))))
                   (skip-empty
                    '())
                   (t
                    (list "")))))
    (parse 0)))

(defun s+ (&rest strings)
  "Return a string which is made of the concatenation of STRINGS."
  (apply #'concatenate 'string strings))

(defun string-concat (list &optional (separator ""))
  "Concatenate the strings in LIST interposing SEPARATOR (default
nothing) between them."
  (reduce #'(lambda (&rest args)
              (if args
                  (s+ (car args) separator (cadr args))
                  ""))
          list))

(defun string-starts-with (prefix string &optional (compare #'string=))
  (let ((prefix-length (length prefix)))
    (and (>= (length string) prefix-length)
         (funcall compare prefix string :end2 prefix-length))))

;; QUEUE

(defstruct queue
  first
  last)

(defgeneric queue-append (queue objects))
(defgeneric queue-pop (queue))
(defgeneric queue-empty-p (queue))

(defmethod queue-append ((queue queue) (objects list))
  (cond ((null (queue-first queue))
         (setf (queue-first queue) objects
               (queue-last queue) (last objects)))
        (t
         (setf (cdr (queue-last queue)) objects
               (queue-last queue) (last objects))))
  queue)

(defmethod queue-append ((queue queue) object)
  (queue-append queue (list object)))

(defmethod queue-pop ((queue queue))
  (prog1 (car (queue-first queue))
    (setf (queue-first queue) (cdr (queue-first queue)))))

(defmethod queue-empty-p ((queue queue))
  (null (queue-first queue)))

;; STREAMS

(defmacro save-file-excursion ((stream &optional position) &body forms)
  "Execute FORMS returning, on exit, STREAM to the position it was
before FORMS.  Optionally POSITION can be set to the starting offset."
  (unless position
    (setf position (gensym)))
  `(let ((,position (file-position ,stream)))
     (unwind-protect (progn ,@forms)
       (file-position ,stream ,position))))

(defun read-file (pathname &key (element-type 'character) (if-does-not-exist :error) default)
  "Read the whole content of file and return it as a sequence which
can be a string, a vector of bytes, or whatever you specify as
ELEMENT-TYPE."
  (with-open-file (in pathname
                      :element-type element-type
                      :if-does-not-exist (unless (eq :value if-does-not-exist)
                                           :error))
    (if in
        (let ((seq (make-array (file-length in) :element-type element-type)))
          (read-sequence seq in)
          seq)
        default)))

;; LAZY

(defstruct promise
  procedure
  value)

(defmacro lazy (form)
  `(make-promise :procedure #'(lambda () ,form)))

(defun forced-p (promise)
  (null (promise-procedure promise)))

(defun force (promise)
  (if (forced-p promise)
      (promise-value promise)
      (prog1 (setf (promise-value promise)
                   (funcall (promise-procedure promise)))
        (setf (promise-procedure promise) nil))))

(defmacro deflazy (name value &optional documentation)
  `(defparameter ,name (lazy ,value)
     ,@(when documentation
             (list documentation))))

;; FIXNUMS

(defmacro f++ (x &optional (delta 1))
  "Same as INCF but hopefully optimised for fixnums."
  `(setf ,x (+ (the fixnum ,x) (the fixnum ,delta))))

;; TIME

(defun week-day->string (day &optional sunday-first)
  "Return the weekday string corresponding to DAY number."
  (elt (if sunday-first
           #("Sunday" "Monday" "Tuesday" "Wednesday" "Thursday" "Friday" "Saturday")
           #("Monday" "Tuesday" "Wednesday" "Thursday" "Friday" "Saturday" "Sunday"))
       day))

(defvar +month-names+  #("January" "February" "March" "April" "May" "June" "July"
                           "August" "September" "October" "November" "December"))

(defun month->string (month)
  "Return the month string corresponding to MONTH number."
  (elt +month-names+ (1- month)))
