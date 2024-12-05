;;;  mime4cl.lisp --- MIME primitives for Common Lisp

;;;  Copyright (C) 2005-2008, 2010 by Walter C. Pelissero
;;;  Copyright (C) 2021-2023 by the TVL Authors

;;;  Author: Walter C. Pelissero <walter@pelissero.de>
;;;  Project: mime4cl

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

(in-package :mime4cl)

(defclass mime-part ()
  ((subtype
    :type (or string null)
    :initarg :subtype
    :accessor mime-subtype
    ;; some mime types don't require a subtype
    :initform nil)
   (type-parameters
    :type list
    :initarg :type-parameters
    :initform '()
    :accessor mime-type-parameters)
   (version
    :type (or string null)
    :initarg :mime-version
    :initform "1.0"
    :accessor mime-version)
   (id
    :initform nil
    :initarg :id
    :reader mime-id)
   (description
    :initform nil
    :initarg :description
    :accessor mime-description)
   (encoding
    :initform :7bit
    :initarg :encoding
    :reader mime-encoding
    :documentation
    "It's supposed to be either:
  :7BIT, :8BIT, :BINARY, :QUOTED-PRINTABLE, :BASE64, a
  X-token or an ietf-token (whatever that means).")
   (disposition
    :type (or string null)
    :initarg :disposition
    :initform nil
    :accessor mime-disposition)
   (disposition-parameters
    :type list
    :initarg :disposition-parameters
    :initform '()
    :accessor mime-disposition-parameters))
  (:documentation
   "Abstract base class for all types of MIME parts."))

(defparameter +redundant-headers+ '(:mime-version
                                    :content-type
                                    :content-id
                                    :content-description
                                    :content-disposition
                                    :content-transfer-encoding)
  "Headers that don't need to be preserved in the  HEADERS slot of MIME-MESSAGE
because they are stored in dedicated slots in MIME-PART.")

(defclass mime-bodily-part (mime-part)
  ((body
    :initarg :body
    :accessor mime-body))
  (:documentation
   "Abstract base class for MIME parts with a body."))

(defclass mime-unknown-part (mime-bodily-part)
  ((type
    :initarg :type
    :reader mime-type
    :documentation
    "The original type string from the MIME header."))
  (:documentation
   "MIME part unknown to this library.  Accepted but not handled."))

(defclass mime-text (mime-bodily-part) ())

;; This turns out to be handy when making methods specialised
;; non-textual attachments.
(defclass mime-binary (mime-bodily-part) ())

(defclass mime-image (mime-binary) ())

(defclass mime-audio (mime-binary) ())

(defclass mime-video (mime-binary) ())

(defclass mime-application (mime-binary) ())

(defclass mime-multipart (mime-part)
  ((parts :initarg :parts
          :accessor mime-parts)))

(defclass mime-message (mime-part)
  ((headers :initarg :headers
            :initform '()
            :type list
            :accessor mime-message-headers)
   (real-message :initarg :body
                 :accessor mime-body)))

(defun mime-part-p (object)
  (typep object 'mime-part))

(defmethod initialize-instance ((part mime-multipart) &key &allow-other-keys)
  (call-next-method)
  ;; The initialization argument of the PARTS slot of a mime-multipart
  ;; is expected to be a list of mime-parts.  Thus, we implicitly
  ;; create the mime parts using the arguments found in this list.
  (with-slots (parts) part
    (when (slot-boundp part 'parts)
      (setf parts
            (mapcar #'(lambda (subpart)
                        (if (mime-part-p subpart)
                            subpart
                            (apply #'make-instance subpart)))
                    parts)))))

(defmethod initialize-instance ((part mime-message) &key &allow-other-keys)
  (call-next-method)
  ;; Allow a list of mime parts to be specified as body of a
  ;; mime-message.  In that case we implicitly create a mime-multipart
  ;; and assign to the body slot.
  (with-slots (real-message headers) part
    (when (and (slot-boundp part 'real-message)
               (consp real-message))
      (setf real-message
            (make-instance 'mime-multipart :parts real-message)))
    ;; Remove headers that are parsed and stored in MIME-PART (i.e.
    ;; REAL-MESSAGE). This prevents redundant storage and rendering of these
    ;; headers as well as MIME= depending on the specific rendering of these
    ;; headers which may diverge between mime4cl and other software. We do this
    ;; here since construction of REAL-MESSAGE may access the HEADERS slot.
    (setf headers
          (delete-if (lambda (h)
                       (member (car h) +redundant-headers+ :test #'string-equal))
                     headers))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun alist= (alist1 alist2 &key (test #'eql))
  (null
   (set-difference alist1 alist2
                   :test #'(lambda (x y)
                             (and (funcall test (car x) (car y))
                                  (funcall test (cdr x) (cdr y)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defgeneric mime= (mime1 mime2)
  (:documentation
   "Return true if MIME1 and MIME2 have equivalent structure and identical bodies (as for EQ)."))

(defmethod mime= ((part1 mime-part) (part2 mime-part))
  (macrolet ((null-or (compare x y)
               `(or (and (not ,x)
                         (not ,y))
                    (and ,x ,y
                         (,compare ,x ,y))))
             (cmp-slot (compare reader)
               `(null-or ,compare (,reader part1) (,reader part2))))
    (and (eq (class-of part1) (class-of part2))
         (cmp-slot string-equal mime-subtype)
         (alist= (mime-type-parameters part1)
                 (mime-type-parameters part2)
                 :test #'string-equal)
         (cmp-slot string= mime-id)
         (cmp-slot string= mime-description)
         (cmp-slot eq mime-encoding)
         (cmp-slot equal mime-disposition)
         (alist= (mime-disposition-parameters part1)
                 (mime-disposition-parameters part2)
                 :test #'string-equal))))

(defmethod mime= ((part1 mime-multipart) (part2 mime-multipart))
  (and (call-next-method)
       (every #'mime= (mime-parts part1) (mime-parts part2))))

(defmethod mime= ((part1 mime-message) (part2 mime-message))
  (and (call-next-method)
       (alist= (mime-message-headers part1) (mime-message-headers part2)
               :test #'string=)
       (mime= (mime-body part1) (mime-body part2))))

(defun mime-body-stream (mime-part)
  (make-input-adapter (mime-body mime-part)))

(defmacro with-input-from-mime-body-stream ((stream part) &body forms)
  `(with-open-stream (,stream (mime-body-stream ,part))
     ,@forms))

(defmethod mime= ((part1 mime-bodily-part) (part2 mime-bodily-part))
  (and (call-next-method)
       (with-input-from-mime-body-stream (in1 part1)
         (with-input-from-mime-body-stream (in2 part2)
           (loop
              for b1 = (read-byte in1 nil)
              for b2 = (read-byte in2 nil)
              always (eq b1 b2)
              while (and b1 b2))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defgeneric get-mime-type-parameter (part name)
  (:documentation
   "Return the MIME type parameter associated to NAME of PART."))

(defgeneric (setf get-mime-type-parameter) (value part name)
  (:documentation
   "Set the MIME type parameter associated to NAME of PART."))

(defmethod get-mime-type-parameter ((part mime-part) name)
  (cdr (assoc name (mime-type-parameters part) :test #'string-equal)))

(defmethod (setf get-mime-type-parameter) (value part name)
  (aif (assoc name (mime-type-parameters part) :test #'string-equal)
       (setf (cdr it) value)
       (push (cons name value)
             (mime-type-parameters part)))
  value)

(defgeneric get-mime-disposition-parameter (part name)
  (:documentation
   "Return the MIME disposition parameter associated to NAME of PART."))

(defmethod get-mime-disposition-parameter ((part mime-part) name)
  (cdr (assoc name (mime-disposition-parameters part) :test #'string-equal)))

(defmethod (setf get-mime-disposition-parameter) (value part name)
  (aif (assoc name (mime-disposition-parameters part) :test #'string-equal)
       (setf (cdr it) value)
       (push (cons name value)
             (mime-disposition-parameters part))))

(defmethod mime-part-file-name ((part mime-part))
  "Return the filename associated to mime PART or NIL if the mime
part doesn't have a file name."
  (or (get-mime-disposition-parameter part :filename)
      (get-mime-type-parameter part :name)))

(defmethod (setf mime-part-file-name) (value (part mime-part))
  "Set the filename associated to mime PART."
  (setf (get-mime-disposition-parameter part :filename) value
        (get-mime-type-parameter part :name) value))

(defun mime-text-charset (part)
  (get-mime-type-parameter part :charset))

(defun split-header-parts (string)
  "Split parts of a MIME headers.  These are divided by
semi-colons not within strings or comments."
  (labels ((skip-comment (pos)
             (loop
                while (< pos (length string))
                do (case (elt string pos)
                     (#\( (setf pos (skip-comment (1+ pos))))
                     (#\\ (incf pos 2))
                     (#\) (return (1+ pos)))
                     (otherwise (incf pos)))
                finally (return pos)))
           (skip-string (pos)
             (loop
                while (< pos (length string))
                do (case (elt string pos)
                     (#\\ (incf pos 2))
                     (#\" (return (1+ pos)))
                     (otherwise (incf pos)))
                finally (return pos))))
    (loop
       with start = 0 and i = 0 and parts = '()
       while (< i (length string))
       do (case (elt string i)
            (#\; (push (subseq string start i) parts)
                 (setf start (incf i)))
            (#\" (setf i (skip-string i)))
            (#\( (setf i (skip-comment (1+ i))))
            (otherwise (incf i)))
       finally (return (mapcar #'string-trim-whitespace (nreverse (cons (subseq string start) parts)))))))

(defun parse-parameter (string)
  "Given a string like \"foo=bar\" return a pair (\"foo\" .
\"bar\").  Return NIL if string is not parsable."
  ;; TODO(sterni): when-let
  (let ((equal-position (position #\= string)))
    (when equal-position
      (let ((key (subseq string  0 equal-position)))
        (if (= equal-position (1- (length string)))
            (cons key "")
            (let ((value (string-trim-whitespace (subseq string (1+ equal-position)))))
              (cons key
                    (if (and (> (length value) 1)
                             (char= #\" (elt value 0)))
                        ;; the syntax of a RFC822 string is more or
                        ;; less the same as the Lisp one: use the Lisp
                        ;; reader
                        (or (ignore-errors (read-from-string value))
                            (subseq value 1))
                        (let ((end (or (position-if #'whitespace-p value)
                                       (length value))))
                          (subseq value 0 end))))))))))

(defun parse-content-type (string)
  "Parse string as a Content-Type MIME header and return a list
of three elements.  The first is the type, the second is the
subtype and the third is an alist of parameters and their values.
Example: (\"text\" \"plain\" ((\"charset\" . \"us-ascii\")...))."
  (let* ((parts (split-header-parts string))
         (content-type-string (car parts))
         (slash (position #\/ content-type-string)))
    ;; You'd be amazed to know how many MUA can't produce an RFC
    ;; compliant message.
    (when slash
      (let ((type (subseq content-type-string 0 slash))
            (subtype (subseq content-type-string (1+ slash))))
        (list type subtype (remove nil (mapcar #'parse-parameter (cdr parts))))))))

(defun parse-content-disposition (string)
  "Parse string as a Content-Disposition MIME header and return a
list.  The first element is the layout, the other elements are
the optional parameters alist.
Example: (\"inline\" (\"filename\" . \"doggy.jpg\"))."
  (let ((parts (split-header-parts string)))
    (cons (car parts) (mapcan #'(lambda (parameter-string)
                                  (awhen (parse-parameter parameter-string)
                                    (list it)))
                              (cdr parts)))))

(defun parse-RFC822-header (string)
  "Parse STRING which should be a valid RFC822 message header and
return two values: a string of the header name and a string of
the header value."
  (let ((colon (position #\: string)))
    (when colon
      (values (string-trim-whitespace (subseq string 0 colon))
              (string-trim-whitespace (subseq string (1+ colon)))))))


(defvar *default-type* '("text" "plain" (("charset" . "us-ascii")))
  "Internal special variable that contains the default MIME type at
any given time of the parsing phase.  There are MIME container parts
that may change this.")

(defvar *mime-types*
  '((:text mime-text)
    (:image mime-image)
    (:audio mime-audio)
    (:video mime-video)
    (:application mime-application)
    (:multipart mime-multipart)
    (:message mime-message)))

(defgeneric print-mime-part (part stream)
  (:documentation
   "Output to STREAM one of the possible human-readable representation
of mime PART.  Binary parts are omitted.  This function can be used to
quote messages, for instance."))

(defun do-multipart-parts (body-stream part-boundary contents-function end-part-function)
  "Read through BODY-STREAM.  Call CONTENTS-FUNCTION at
each (non-boundary) line or END-PART-FUNCTION at each PART-BOUNDARY."
  (let* ((boundary (s+ "--" part-boundary))
         (boundary-length (length boundary)))
    (labels ((output-line (line)
               (funcall contents-function line))
             (end-part ()
               (funcall end-part-function))
             (last-part ()
               (end-part)
               (return-from do-multipart-parts))
             (process-line (line)
               (cond ((not (string-starts-with boundary line))
                      ;; normal line
                      (output-line line))
                     ((and (= (length (string-trim-whitespace line))
                              (+ 2 boundary-length))
                           (string= "--" line :start2 boundary-length))
                      ;; end of the last part
                      (last-part))
                     ;; according to RFC2046 "the boundary may be followed
                     ;; by zero or more characters of linear whitespace"
                     ((= (length (string-trim-whitespace line)) boundary-length)
                      ;; beginning of the next part
                      (end-part))
                     (t
                      ;; the line boundary is followed by some
                      ;; garbage; we treat it as a normal line
                      (output-line line)))))
      (loop
         for line = (read-line body-stream nil)
         ;; we should never reach the end of a proper multipart MIME
         ;; stream, but we don't want to be fooled by corrupted ones,
         ;; so we check for EOF
         unless line
         do (last-part)
         do (process-line line)))))

(defun index-multipart-parts (body-stream part-boundary)
  "Read from BODY-STREAM and return the file offset of the MIME parts
separated by PART-BOUNDARY."
  (let ((parts '())
        (start 0)
        (len 0)
        (beginning-of-part-p t))
    (flet ((sum-chars (line)
             (incf len (length line))
             ;; account for the #\newline
             (if beginning-of-part-p
                 (setf beginning-of-part-p nil)
                 (incf len)))
           (end-part ()
             (setf beginning-of-part-p t)
             (push (cons start (+ start len)) parts)
             (setf start (file-position body-stream)
                   len 0)))
      (do-multipart-parts body-stream part-boundary #'sum-chars #'end-part)
      ;; the first part is all the stuff up to the first boundary;
      ;; just junk
      (cdr (nreverse parts)))))

(defgeneric encode-mime-part (part stream))
(defgeneric encode-mime-body (part stream))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun write-mime-header (part stream)
  (when (mime-version part)
    (format stream "~&MIME-Version: ~A~%" (mime-version part)))
  (format stream "~&Content-Type: ~A~:{; ~A=~S~}~%" (mime-type-string part)
          (mapcar #'(lambda (pair)
                      (list (car pair) (cdr pair)))
                  (mime-type-parameters part)))
  (awhen (mime-encoding part)
    (format stream "Content-Transfer-Encoding: ~A~%" it))
  (awhen (mime-description part)
    (format stream "Content-Description: ~A~%" it))
  (when (mime-disposition part)
    (format stream "Content-Disposition: ~A~:{; ~A=~S~}~%"
            (mime-disposition part)
            (mapcar #'(lambda (pair)
                        (list (car pair) (cdr pair)))
                    (mime-disposition-parameters part))))
  (awhen (mime-id part)
    (format stream "Content-ID: ~A~%" it))
  (terpri stream))

(defmethod encode-mime-part ((part mime-part) stream)
  (write-mime-header part stream)
  (encode-mime-body part stream))

(defmethod encode-mime-part ((part mime-message) stream)
  ;; tricky: we have to mix the MIME headers with the message headers, i.e.
  ;; ENCODE-MIME-PART will output additional headers
  (dolist (h (mime-message-headers part))
    (unless (stringp (car h))
      (setf (car h)
            (string-capitalize (car h))))
    (format stream "~A: ~A~%"
            (car h) (cdr h)))
  (encode-mime-part (mime-body part) stream))

(defmethod encode-mime-part ((part mime-multipart) stream)
  (declare (ignore stream)) ; call-next-method
  ;; choose a boundary if not already set
  (let* ((original-boundary (get-mime-type-parameter part :boundary))
         (boundary (choose-boundary (mime-parts part) original-boundary)))
    (unless (and original-boundary
                 (string= boundary original-boundary))
      (setf (get-mime-type-parameter part :boundary) boundary))
    (call-next-method)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defmethod encode-mime-body ((part mime-part) stream)
  (with-input-from-mime-body-stream (in part)
    (encode-stream in stream (mime-encoding part))))

(defmethod encode-mime-body ((part mime-message) stream)
  (encode-mime-body (mime-body part) stream))

(defmethod encode-mime-body ((part mime-multipart) stream)
  (let ((boundary (or (get-mime-type-parameter part :boundary)
                      (setf (get-mime-type-parameter part :boundary)
                            (choose-boundary (mime-parts part))))))
    (dolist (p (mime-parts part))
      (format stream "~%--~A~%" boundary)
      (encode-mime-part p stream))
    (format stream "~%--~A--~%" boundary)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun time-RFC822-string (&optional (epoch (get-universal-time)))
  "Return a string describing the current time according to
the RFC822."
  (multiple-value-bind (ss mm hh day month year week-day dst tz) (decode-universal-time epoch)
    (declare (ignore dst))
    (format nil "~A, ~A ~A ~2,'0D ~2,'0D:~2,'0D:~2,'0D ~:[-~;+~]~2,'0D~2,'0D"
            (subseq (week-day->string week-day) 0 3)
            day (subseq (month->string month) 0 3) (mod year 100) hh mm ss
            (plusp tz) (abs (truncate tz)) (mod (* 60 tz) 60))))

(defun parse-RFC822-date (date-string)
  "Parse a RFC822 compliant date string and return an universal
time."
  ;; if we can't parse it, just return NIL
  (ignore-errors
    ;; skip the optional DoW
    (awhen (position #\, date-string)
      (setf date-string (subseq date-string (1+ it))))
    (destructuring-bind (day month year time &optional tz &rest rubbish)
        (split-at '(#\space #\tab) date-string)
      (declare (ignore rubbish))
      (destructuring-bind (hh mm &optional ss) (split-string-at-char time #\:)
        (encode-universal-time
         (if ss
             (read-from-string ss)
             0)
         (read-from-string mm)
         (read-from-string hh)
         (read-from-string day)
         (1+ (position month
                       '("Jan" "Feb" "Mar" "Apr" "May" "Jun"
                         "Jul" "Aug" "Sep" "Oct" "Nov" "Dec")
                       :test #'string-equal))
         (read-from-string year)
         (when (and tz (or (char= #\+ (elt tz 0))
                           (char= #\- (elt tz 0))))
           (/ (read-from-string tz) 100)))))))

(defun read-RFC822-headers (stream &optional required-headers)
  "Read RFC822 compliant headers from STREAM and return them in a
alist of keyword and string pairs.  REQUIRED-HEADERS is a list of
header names we are interested in; if NIL return all headers
found in STREAM."
  ;; the skip-header variable is to avoid the mistake of appending a
  ;; continuation line of a header we don't want to a header we want
  (loop
     with headers = '() and skip-header = nil
     for line = (let ((line (read-line stream nil)))
                  ;; skip the Unix "From " header if present
                  (if (string-starts-with "From " line)
                      (read-line stream nil)
                      line))
     then (read-line stream nil)
     while (and line
                (not (zerop (length line))))
     do (if (whitespace-p (elt line 0))
            (unless (or skip-header
                        (null headers))
              (setf (cdar headers) (s+ (cdar headers) '(#\newline) line)))
            (multiple-value-bind (name value) (parse-RFC822-header line)
              ;; the line contained rubbish instead of an header: we
              ;; play nice and return as we were at the end of the
              ;; headers
              (unless name
                (return (nreverse headers)))
              (if (or (null required-headers)
                      (member name required-headers :test #'string-equal))
                  (progn
                    (push (cons name value) headers)
                    (setf skip-header nil))
                  (setf skip-header t))))
     finally (return (nreverse headers))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defgeneric mime-message (thing)
  (:documentation
   "Convert THING to a MIME-MESSAGE object."))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun mime-message-header-values (name message &key decode)
  "Return all values of the header with NAME in MESSAGE, optionally decoding
  it according to RFC2047 if :DECODE is T."
  (loop ;; A header may occur multiple times
        for header in (mime-message-headers message)
        ;; MIME Headers should be case insensitive
        ;; https://stackoverflow.com/a/6143644
        when (string-equal (car header) name)
        collect (if decode
                    (decode-RFC2047 (cdr header))
                    (cdr header))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar *lazy-mime-decode* t
  "If true don't  decode mime bodies in memory.")

(defgeneric decode-mime-body (part input-stream))

(defmethod decode-mime-body ((part mime-part) (stream flexi-stream))
  (let ((base (flexi-stream-root-stream stream)))
    (if *lazy-mime-decode*
        (setf (mime-body part)
              (make-file-portion :data (etypecase base
                                         (vector-stream
                                          (flexi-streams::vector-stream-vector base))
                                         (file-stream
                                          (pathname base)))
                                 :encoding (mime-encoding part)
                                 :start (flexi-stream-position stream)
                                 :end (flexi-stream-bound stream)))
        (call-next-method))))

(defmethod decode-mime-body ((part mime-part) (stream file-stream))
  (if *lazy-mime-decode*
      (setf (mime-body part)
            (make-file-portion :data (pathname stream)
                               :encoding (mime-encoding part)
                               :start (file-position stream)))
      (call-next-method)))

(defmethod decode-mime-body ((part mime-part) (stream vector-stream))
  (if *lazy-mime-decode*
      (setf (mime-body part)
            (make-file-portion :data (flexi-streams::vector-stream-vector stream)
                               :encoding (mime-encoding part)
                               :start (flexi-streams::vector-stream-index stream)))
      (call-next-method)))

(defmethod decode-mime-body ((part mime-part) stream)
  (setf (mime-body part)
        (decode-stream-to-sequence stream (mime-encoding part))))

(defmethod decode-mime-body ((part mime-multipart) stream)
  "Decode STREAM according to PART characteristics and return a
list of MIME parts."
  (save-file-excursion (stream)
    (let ((offsets (index-multipart-parts stream (get-mime-type-parameter part :boundary))))
      (setf (mime-parts part)
            (mapcar #'(lambda (p)
                        (destructuring-bind (start . end) p
                          (let ((*default-type* (if (eq :digest (mime-subtype part))
                                                    '("message" "rfc822" ())
                                                    '("text" "plain" (("charset" . "us-ascii")))))
                                (in (make-positioned-flexi-input-stream stream
                                                                        :position start
                                                                        :bound end
                                                                        :ignore-close t)))
                            (read-mime-part in))))
                    offsets)))))

(defmethod decode-mime-body ((part mime-message) stream)
  "Read from STREAM the body of PART.  Return the decoded MIME
body."
  (setf (mime-body part)
        (read-mime-message stream)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar +known-encodings+ '(:7BIT :8BIT :BINARY :QUOTED-PRINTABLE :BASE64)
  "List of known content encodings.")

(defun keywordify-encoding (string)
  "Return a keyword for a content transfer encoding string.
Return STRING itself if STRING is an unkown encoding."
  (when string
    (aif (member string +known-encodings+ :test #'string-equal)
         (car it)
         string)))

(defun header (name headers)
  (let ((elt (assoc name headers :test #'string-equal)))
    (values (cdr elt) (car elt))))

(defun (setf header) (value name headers)
  (let ((entry (assoc name headers :test #'string-equal)))
    (unless entry
      (error "missing header ~A can't be set" name))
    (setf (cdr entry) value)))

(defun make-mime-part (headers stream)
  "Create a MIME-PART object based on HEADERS and a body which
has to be read from STREAM.  If the mime part type can't be
guessed from the headers, use the *DEFAULT-TYPE*."
  (flet ((hdr (what)
           (header what headers)))
    (destructuring-bind (type subtype parms)
        (or
         (aand (hdr :content-type)
               (parse-content-type it))
         *default-type*)
      (let* ((class (or (cadr (assoc type *mime-types* :test #'string-equal))
                        'mime-unknown-part))
             (disp (aif (hdr :content-disposition)
                        (parse-content-disposition it)
                        (values nil nil)))
             (part (make-instance class
                                  :type (hdr :content-type)
                                  :subtype subtype
                                  :type-parameters parms
                                  :disposition (car disp)
                                  :disposition-parameters (cdr disp)
                                  :mime-version (hdr :mime-version)
                                  :encoding (or (keywordify-encoding
                                                 (hdr :content-transfer-encoding))
                                                :7bit) ; default per RFC2045
                                  :description (hdr :content-description)
                                  :id (hdr :content-id)
                                  :allow-other-keys t)))
        (decode-mime-body part stream)
        part))))

(defun read-mime-part (stream)
  "Read mime part from STREAM.  Return a MIME-PART object."
  (let ((headers (read-rfc822-headers stream
                                      '(:mime-version :content-transfer-encoding :content-type
                                        :content-disposition :content-description :content-id))))
    (make-mime-part headers stream)))

(defun read-mime-message (stream)
  "Main function to read a MIME message from a stream.  It
returns a MIME-MESSAGE object."
  (let ((headers (read-rfc822-headers stream))
        (*default-type* '("text" "plain" (("charset" . "us-ascii")))))
    (flet ((hdr (what)
             (header what headers)))
      (destructuring-bind (type subtype parms)
          (or (aand (hdr :content-type)
                    (parse-content-type it))
              *default-type*)
        (declare (ignore type subtype))
        (make-instance 'mime-message
                       :headers headers
                       ;; this is just for easy access
                       :type-parameters parms
                       :body (make-mime-part headers stream))))))

(defmethod mime-message ((msg mime-message))
  msg)

(defmethod mime-message ((msg string))
  (mime-message (flexi-streams:string-to-octets msg)))

(defmethod mime-message ((msg vector))
  (with-input-from-sequence (in msg)
    (mime-message in)))

(defmethod mime-message ((msg pathname))
  (with-open-file (in msg :element-type '(unsigned-byte 8))
    (mime-message in)))

(defmethod mime-message ((msg stream))
  (mime-message (make-flexi-stream msg)))

(defmethod mime-message ((msg flexi-stream))
  (read-mime-message msg))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defgeneric mime-part (object)
  (:documentation
   "Promote object, if necessary, to MIME-PART."))

(defmethod mime-part ((object string))
  (make-instance 'mime-text :subtype "plain" :body object))

(defmethod mime-part ((object pathname))
  (make-instance 'mime-application
                 :subtype "octect-stream"
                 :content-transfer-encoding :base64
                 :body (read-file object :element-type '(unsigned-byte 8))))

(defmethod mime-part ((object mime-part))
  object)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defmethod make-encoded-body-stream ((part mime-bodily-part))
  (let ((body (mime-body part)))
    (make-instance (case (mime-encoding part)
                     (:base64
                      'base64-encoder-input-stream)
                     (:quoted-printable
                      'quoted-printable-encoder-input-stream)
                     (otherwise
                      '8bit-encoder-input-stream))
                   :underlying-stream
                   (make-input-adapter body))))

(defun choose-boundary (parts &optional default)
  (labels ((match-in-parts (boundary parts)
             (loop
                for p in parts
                thereis (typecase p
                          (mime-multipart
                           (match-in-parts boundary (mime-parts p)))
                          (mime-bodily-part
                           (match-in-body p boundary)))))
           (match-in-body (part boundary)
             (with-open-stream (in (make-encoded-body-stream part))
               (loop
                  for line = (read-line in nil)
                  while line
                  when (string= line boundary)
                  return t
                  finally (return nil)))))
    (do ((boundary (if default
                       (format nil "--~A" default)
                       #1=(format nil "--~{~36R~}"
                                  (loop
                                     for i from 0 below 20
                                     collect (random 36))))
                   #1#))
        ((not (match-in-parts boundary parts)) (subseq boundary 2)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defmethod print-mime-part ((part mime-multipart) (out stream))
  (case (mime-subtype part)
    (:alternative
     ;; try to choose something simple to print or the first thing
     (let ((parts (mime-parts part)))
       (print-mime-part (or (find-if #'(lambda (part)
                                         (and (eq (class-of part) (find-class 'mime-text))
                                              (eq (mime-subtype part) :plain)))
                                     parts)
                            (car parts)) out)))
    (otherwise
     (dolist (subpart (mime-parts part))
       (print-mime-part subpart out)))))

;; This is WRONG.  Here we don't use any special character encoding
;; because we don't know which one we should use.  Messages written in
;; anything but ASCII will likely be unreadable -wcp11/10/07.
(defmethod print-mime-part ((part mime-text) (out stream))
  (let ((body (mime-body part)))
    (etypecase body
      (string
       (write-string body out))
      (vector
       (loop
          for byte across body
          do (write-char (code-char byte) out)))
      (file-portion
       (redirect-stream (open-decoded-file-portion body) out))
      (pathname
       (with-open-file (in body)
         (redirect-stream in out))))))

(defmethod print-mime-part ((part mime-message) (out stream))
  (flet ((hdr (name)
           (multiple-value-bind (value tag)
               (header name (mime-message-headers part))
             (cons tag value))))
    (dolist (h (mapcar #'hdr '("from" "subject" "to" "date" "x-march-archive-id")))
      (when h
        (format out "~&~A: ~A" (car h) (cdr h))))
    (format out "~2%")
    (print-mime-part (mime-body part) out)))

(defmethod print-mime-part ((part mime-part) (out stream))
  (format out "~&[ ~A subtype=~A ~@[description=~S ~]]~%"
          (type-of part) (mime-subtype part) (mime-description part)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defgeneric find-mime-part-by-path (mime path)
  (:documentation
   "Return a subpart of MIME identified by PATH, which is a list of
integers.  For example '(2 3 1) is the first part of the third of the
second in MIME."))

(defmethod find-mime-part-by-path ((part mime-part) path)
  (if (null path)
      part
      (error "~S doesn't have subparts" part)))

(defmethod find-mime-part-by-path ((part mime-message) path)
  (if (null path)
      part
      (if (= 1 (car path))
          (find-mime-part-by-path (mime-body part) (cdr path))
          (error "~S may have just one subpart, but part ~D was requested (parts are enumerated base 1)."
                 part (car path)))))

(defmethod find-mime-part-by-path ((part mime-multipart) path)
  (if (null path)
      part
      (let ((parts (mime-parts part))
            (part-number (car path)))
        (if (<= 1 part-number (length parts))
            (find-mime-part-by-path (nth (1- (car path)) (mime-parts part)) (cdr path))
            (error "~S has just ~D subparts, but part ~D was requested (parts are enumerated base 1)."
                   part (length parts) part-number)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defgeneric find-mime-part-by-id (part id)
  (:documentation
   "Return a subpart of PAR, whose Content-ID is the same as ID, which
is a string."))

(defmethod find-mime-part-by-id ((part mime-part) id)
  (when (string= id (mime-id part))
    part))

(defmethod find-mime-part-by-id ((part mime-message) id)
  (find-mime-part-by-id (mime-body part) id))

(defmethod find-mime-part-by-id ((part mime-multipart) id)
  (or (call-next-method)
      (some #'(lambda (p)
                (find-mime-part-by-id p id))
            (mime-parts part))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defgeneric find-mime-text-part (msg)
  (:documentation
   "Return message if it is a text message or first text part.
   If no suitable text part is found, return NIL."))

(defmethod find-mime-text-part ((part mime-text))
  part) ; found our target

(defmethod find-mime-text-part ((msg mime-message))
  ;; mime-body is either a mime-part or mime-multipart
  (find-mime-text-part (mime-body msg)))

(defmethod find-mime-text-part ((parts mime-multipart))
  ;; multipart messages may have a body, otherwise we
  ;; search for the first text part
  (or (call-next-method)
      (find-if #'find-mime-text-part (mime-parts parts))))

(defmethod find-mime-text-part ((part mime-part))
  nil) ; default case

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defgeneric mime-type-string (mime-part)
  (:documentation
   "Return the string describing the MIME part."))

(defmethod mime-type-string ((part mime-text))
  (format nil "text/~A" (mime-subtype part)))

(defmethod mime-type-string ((part mime-image))
  (format nil "image/~A" (mime-subtype part)))

(defmethod mime-type-string ((part mime-audio))
  (format nil "audio/~A" (mime-subtype part)))

(defmethod mime-type-string ((part mime-video))
  (format nil "video/~A" (mime-subtype part)))

(defmethod mime-type-string ((part mime-application))
  (format nil "application/~A" (mime-subtype part)))

(defmethod mime-type-string ((part mime-multipart))
  (format nil "multipart/~A" (mime-subtype part)))

(defmethod mime-type-string ((part mime-message))
  (format nil "message/~A" (mime-subtype part)))

(defmethod mime-type-string ((part mime-unknown-part))
  (mime-type part))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defgeneric map-parts (function mime-part)
  (:documentation
   "Recursively map FUNCTION to MIME-PART or its components."))

;; Here we wrongly assume that we'll never want to replace messages
;; and multiparts altogether.  If you need to do so you have to write
;; your own mapping functions.

(defmethod map-parts ((function function) (part mime-part))
  (funcall function part))

(defmethod map-parts ((function function) (part mime-message))
  (setf (mime-body part) (map-parts function (mime-body part)))
  part)

(defmethod map-parts ((function function) (part mime-multipart))
  (setf (mime-parts part) (mapcar #'(lambda (p)
                                      (map-parts function p))
                                  (mime-parts part)))
  part)

;; apply-on-parts is like map-parts but doesn't modify the parts (at least
;; not implicitly)

(defgeneric apply-on-parts (function part))

(defmethod apply-on-parts ((function function) (part mime-part))
  (funcall function part))

(defmethod apply-on-parts ((function function) (part mime-multipart))
  (dolist (p (mime-parts part))
    (apply-on-parts function p)))

(defmethod apply-on-parts ((function function) (part mime-message))
  (apply-on-parts function (mime-body part)))

(defmacro do-parts ((var mime-part) &body body)
  `(apply-on-parts #'(lambda (,var) ,@body) ,mime-part))
