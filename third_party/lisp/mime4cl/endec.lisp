;;;  endec.lisp --- encoder/decoder functions

;;;  Copyright (C) 2005-2008, 2010 by Walter C. Pelissero
;;;  Copyright (C) 2023 by The TVL Authors

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

(defun redirect-stream (in out &key (buffer-size 4096))
  "Consume input stream IN and write all its content to output stream OUT.
The streams' element types need to match."
  (let ((buf (make-array buffer-size :element-type (stream-element-type in))))
    (loop for pos = (read-sequence buf in)
          while (> pos 0)
          do (write-sequence buf out :end pos))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Thank you SBCL for rendering constants totally useless!
(defparameter +base64-encode-table+
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")

(declaim (type simple-string +base64-encode-table+))

(defvar *base64-line-length* 76
  "Maximum length of the encoded base64 line.  NIL means it can
be of unlimited length \(no line breaks will be done by the
encoding function).")

(defvar *quoted-printable-line-length* 72
  "Maximum length of the encoded quoted printable line.  NIL
means it can be of unlimited length \(no line breaks will be done
by the encoding function).")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defclass decoder ()
  ((input-function :initarg :input-function
                   :reader decoder-input-function
                   :type function
                   :documentation
                   "Function is called repeatedly by the decoder methods to get the next character.
It should return a character os NIL (indicating EOF)."))
  (:documentation
   "Abstract base class for decoders."))

(defclass parsing-decoder (decoder)
  ((parser-errors :initform nil
                  :initarg :parser-errors
                  :reader decoder-parser-errors
                  :type boolean))
  (:documentation
   "Abstract base class for decoders that do parsing."))

(defclass encoder ()
  ((output-function :initarg :output-function
                    :reader encoder-output-function
                    :type function
                    :documentation
                    "Function is called repeatedly by the encoder methods to output a character.
It should expect a character as its only argument."))
  (:documentation
   "Abstract base class for encoders."))

(defclass line-encoder (encoder)
  ((column :initform 0
           :type fixnum)
   (line-length :initarg :line-length
                :initform nil
                :reader encoder-line-length
                :type (or fixnum null)))
  (:documentation
   "Abstract base class for line encoders."))

(defclass 8bit-decoder (decoder)
  ()
  (:documentation
   "Class for decoders that do nothing."))

(defclass 8bit-encoder (encoder)
  ()
  (:documentation
   "Class for encoders that do nothing."))

(defclass 7bit-decoder (decoder)
  ()
  (:documentation
   "Class for decoders that do nothing."))

(defclass 7bit-encoder (encoder)
  ()
  (:documentation
   "Class for encoders that do nothing."))

(defclass byte-decoder (decoder)
  ()
  (:documentation
   "Class for decoders that turns chars to bytes."))

(defclass byte-encoder (encoder)
  ()
  (:documentation
   "Class for encoders that turns bytes to chars."))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defgeneric encoder-write-byte (encoder byte))
(defgeneric encoder-finish-output (encoder))
(defgeneric decoder-read-byte (decoder))

(defmethod encoder-finish-output ((encoder encoder))
  (values))

(defmethod encoder-write-byte ((encoder 8bit-encoder) byte)
  (funcall (slot-value encoder 'output-function)
           (code-char byte))
  (values))

(defmethod decoder-read-byte ((decoder 8bit-decoder))
  (awhen (funcall (slot-value decoder 'input-function))
    (char-code it)))

(defmethod encoder-write-byte ((encoder 7bit-encoder) byte)
  (funcall (slot-value encoder 'output-function)
           (code-char (logand #x7F byte)))
  (values))

(defmethod decoder-read-byte ((decoder 7bit-decoder))
  (awhen (funcall (slot-value decoder 'input-function))
    (logand #x7F (char-code it))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun decoder-read-sequence (sequence decoder &key (start 0) (end (length sequence)))
  (declare (optimize (speed 3) (safety 0) (debug 0))
           (type fixnum start end)
           (type vector sequence))
  (loop
     for i fixnum from start below end
     for byte = (decoder-read-byte decoder)
     while byte
     do (setf (aref sequence i) byte)
     finally (return i)))

(defun decoder-read-line (decoder)
  (with-output-to-string (str)
    (loop
       for byte = (decoder-read-byte decoder)
       unless byte
       do (return-from decoder-read-line nil)
       do (let ((c (code-char byte)))
            (cond ((char= c #\return)
                   ;; skip the newline
                   (decoder-read-byte decoder)
                   (return nil))
                  ((char= c #\newline)
                   ;; the #\return was missing
                   (return nil))
                  (t (write-char c str)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(declaim (inline parse-hex))
(defun parse-hex (c1 c2)
  "Parse two characters as hexadecimal and return their combined
value."
  (declare (optimize (speed 3) (safety 0) (debug 0))
           (type character c1 c2))
  (flet ((digit-value (char)
           (or (position char "0123456789ABCDEF")
               (return-from parse-hex nil))))
    (+ (* 16 (digit-value c1))
       (digit-value c2))))

(defclass quoted-printable-decoder (parsing-decoder)
  ((saved-bytes :initform (make-queue))))

(defmethod decoder-read-byte ((decoder quoted-printable-decoder))
  (declare (optimize (speed 3) (safety 0) (debug 0)))
  (with-slots (input-function saved-bytes parser-errors) decoder
    (declare (type function input-function))
    (labels ((saveb (b)
               (queue-append saved-bytes b)
               (values))
             (save (c)
               (saveb (char-code c)))
             (push-next ()
               (let ((c (funcall input-function)))
                 (declare (type (or null character) c))
                 (cond ((not c))
                       ((or (char= c #\space)
                            (char= c #\tab))
                        (save c)
                        (push-next))
                       ((char= c #\=)
                        (let ((c1 (funcall input-function)))
                          (cond ((not c1)
                                 (save #\=))
                                ((char= c1 #\return)
                                 ;; soft line break: skip the next
                                 ;; character which we assume to be a
                                 ;; newline (pity if it isn't)
                                 (funcall input-function)
                                 (push-next))
                                ((char= c1 #\newline)
                                 ;; soft line break: the #\return is
                                 ;; missing, but we are tolerant
                                 (push-next))
                                (t
                                 ;; hexadecimal sequence: get the 2nd digit
                                 (let ((c2 (funcall input-function)))
                                   (if c2
                                       (aif (parse-hex c1 c2)
                                            (saveb it)
                                            (if parser-errors
                                                (error "invalid hex sequence ~A~A" c1 c2)
                                                (progn
                                                  (save #\=)
                                                  (save c1)
                                                  (save c2))))
                                       (progn
                                         (save c)
                                         (save c1))))))))
                       (t
                        (save c))))))
      (or (queue-pop saved-bytes)
          (progn
            (push-next)
            (queue-pop saved-bytes))))))

(defmacro make-encoder-loop (encoder-class input-form output-form)
  (with-gensyms (encoder byte)
    `(loop
        with ,encoder = (make-instance ',encoder-class
                                       :output-function #'(lambda (char) ,output-form))
        for ,byte = ,input-form
        while ,byte
        do (encoder-write-byte ,encoder ,byte)
        finally (encoder-finish-output ,encoder))))

(defmacro make-decoder-loop (decoder-class input-form output-form &key parser-errors)
  (with-gensyms (decoder)
    `(loop
        with ,decoder = (make-instance ',decoder-class
                                       :input-function #'(lambda () ,input-form)
                                       :parser-errors ,parser-errors)
        for byte = (decoder-read-byte ,decoder)
        while byte
        do ,output-form)))

(defun decode-quoted-printable-stream (in out &key parser-errors)
  "Read from stream IN a quoted printable text and write to
binary output OUT the decoded stream of bytes."
  (make-decoder-loop quoted-printable-decoder
                     (read-byte in nil) (write-byte byte out)
                     :parser-errors parser-errors))

(defmacro make-stream-to-sequence-decoder (decoder-class input-form &key parser-errors)
  "Decode the character stream STREAM and return a sequence of bytes."
  (with-gensyms (output-sequence)
    `(let ((,output-sequence (make-array 0
                                         :element-type '(unsigned-byte 8)
                                         :fill-pointer 0
                                         :adjustable t)))
       (make-decoder-loop ,decoder-class ,input-form
                          (vector-push-extend byte ,output-sequence)
                          :parser-errors ,parser-errors)
       ,output-sequence)))

(defun decode-quoted-printable-stream-to-sequence (stream &key parser-errors)
  "Read from STREAM a quoted printable text and return a vector of
bytes."
  (make-stream-to-sequence-decoder quoted-printable-decoder
    (read-char stream nil)
    :parser-errors parser-errors))

(defun decode-quoted-printable-string (string &key (start 0) (end (length string)) parser-errors)
  "Decode STRING as quoted printable sequence of characters and
return a decoded sequence of bytes."
  (with-input-from-string (in string :start start :end end)
    (decode-quoted-printable-stream-to-sequence in :parser-errors parser-errors)))

(defclass quoted-printable-encoder (line-encoder)
  ((line-length :initform *quoted-printable-line-length*
                :type (or fixnum null))
   (pending-space :initform nil
                  :type boolean)))

(defmethod encoder-write-byte ((encoder quoted-printable-encoder) byte)
  (declare (optimize (speed 3) (safety 0) (debug 0))
           (type (unsigned-byte 8) byte))
  (with-slots (output-function column pending-space line-length) encoder
    (declare (type function output-function)
             (type fixnum column)
             (type (or fixnum null) line-length)
             (type boolean pending-space))
    (labels ((out (c)
               (funcall output-function c)
               (values))
             (outs (str)
               (declare (type simple-string str))
               (loop
                  for c across str
                  do (out c))
               (values))
             (out2hex (x)
               (declare (type fixnum x))
               (multiple-value-bind (a b) (truncate x 16)
                 (out (digit-char a 16))
                 (out (digit-char b 16)))))
      (cond ((= byte #.(char-code #\newline))
             (when pending-space
               (outs "=20")
               (setf pending-space nil))
             (out #\newline)
             (setf column 0))
            ((= byte #.(char-code #\space))
             (if pending-space
                 (progn
                   (out #\space)
                   (f++ column))
                 (setf pending-space t)))
            (t
             (when pending-space
               (out #\space)
               (f++ column)
               (setf pending-space nil))
             (cond ((or (< byte 32)
                        (= byte #.(char-code #\=))
                        (> byte 126))
                    (out #\=)
                    (out2hex byte)
                    (f++ column 3))
                   (t
                    (out (code-char byte))
                    (f++ column)))))
      (when (and line-length
                 (>= column line-length))
        ;; soft line break
        (outs #.(coerce '(#\= #\newline) 'string))
        (setf column 0)))))

(defmethod encoder-finish-output ((encoder quoted-printable-encoder))
  (declare (optimize (speed 3) (safety 0) (debug 0)))
  (with-slots (pending-space output-function) encoder
    (declare (type boolean pending-space)
             (type function output-function))
    (when pending-space
      (flet ((outs (s)
               (declare (type simple-string s))
               (loop
                  for c across s
                  do (funcall output-function c))))
        (setf pending-space nil)
        (outs "=20")))))

(defun encode-quoted-printable-stream (in out)
  "Read from IN a stream of bytes and write to OUT a stream of
characters quoted printables encoded."
  (make-encoder-loop quoted-printable-encoder
                     (read-byte in nil)
                     (write-char char out)))

(defun encode-quoted-printable-sequence-to-stream (sequence stream &key (start 0) (end (length sequence)))
  "Encode the sequence of bytes SEQUENCE and write to STREAM a
quoted printable sequence of characters."
  (let ((i start))
    (make-encoder-loop quoted-printable-encoder
     (when (< i end)
       (prog1 (elt sequence i)
         (f++ i)))
     (write-char char stream))))

(defun encode-quoted-printable-sequence (sequence &key (start 0) (end (length sequence)))
  "Encode the sequence of bytes SEQUENCE into a quoted printable
string and return it."
  (with-output-to-string (out)
    (encode-quoted-printable-sequence-to-stream sequence out :start start :end end)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defclass base64-encoder (line-encoder)
  ((line-length :initform *base64-line-length*)
   (bitstore :initform 0
             :type fixnum)
   (bytecount :initform 0
              :type fixnum))
  (:documentation
   "Class for Base64 encoder output streams."))


(eval-when (:load-toplevel :compile-toplevel)
  (unless (> most-positive-fixnum (expt 2 (* 8 3)))))

(macrolet ((with-encoder (encoder &body forms)
             `(with-slots (bitstore line-length column bytecount output-function) ,encoder
                (declare (type fixnum column)
                         (type fixnum bitstore bytecount)
                         (type (or fixnum null) line-length)
                         (type function output-function))
                (labels ((emitr (i b)
                           (declare (type fixnum i b))
                           (unless (zerop i)
                             (emitr (1- i) (ash b -6)))
                           (emitc
                            (char +base64-encode-table+ (logand b #x3F)))
                           (values))
                         (out (c)
                           (funcall output-function c))
                         (eol ()
                           (progn
                             (out #\return)
                             (out #\newline)))
                         (emitc (char)
                           (out char)
                           (f++ column)
                           (when (and line-length
                                      (>= column line-length))
                             (setf column 0)
                             (eol))))
                  (declare (inline out eol emitc)
                           (ignorable (function emitr) (function out) (function eol) (function emitc)))
                  ,@forms))))
  ;; For this function to work correctly, the FIXNUM must be at least
  ;; 24 bits.
  (defmethod encoder-write-byte ((encoder base64-encoder) byte)
    (declare (optimize (speed 3) (safety 0) (debug 0))
             (type (unsigned-byte 8) byte))
    (with-encoder encoder
      (setf bitstore (logior byte (the fixnum (ash bitstore 8))))
      (f++ bytecount)
      (when (= 3 bytecount)
        (emitr 3 bitstore)
        (setf bitstore 0
              bytecount 0)))
    (values))

  (defmethod encoder-finish-output ((encoder base64-encoder))
    (with-encoder encoder
      (unless (zerop bytecount)
        (multiple-value-bind (saved6 rest) (truncate (* bytecount 8) 6)
          (setf bitstore (ash bitstore (- 6 rest)))
          (emitr saved6 bitstore)
          (dotimes (x (- 3 saved6))
            (emitc #\=))))
      (when (and line-length
                 (not (zerop column)))
        (eol)))
    (values)))

(defun encode-base64-stream (in out)
  "Read a byte stream from IN and write to OUT the encoded Base64
character stream."
  (make-encoder-loop base64-encoder (read-byte in nil)
                     (write-char char out)))

(defun encode-base64-sequence-to-stream (sequence stream &key (start 0) (end (length sequence)))
  "Encode the sequence of bytes SEQUENCE and write to STREAM the
Base64 character sequence."
  (let ((i start))
    (make-encoder-loop base64-encoder
                       (when (< i end)
                         (prog1 (elt sequence i)
                           (incf i)))
                       (write-char char stream))))

(defun encode-base64-sequence (sequence &key (start 0) (end (length sequence)))
  "Encode the sequence of bytes SEQUENCE into a Base64 string and
return it."
  (with-output-to-string (out)
    (encode-base64-sequence-to-stream sequence out :start start :end end)))

(defun decode-base64-stream (in out &key parser-errors)
  "Read from IN a stream of characters Base64 encoded and write
to OUT a stream of decoded bytes."
  ;; parser-errors are ignored for base64
  (declare (ignore parser-errors))
  (redirect-stream (make-instance 'qbase64:decode-stream
                                  :underlying-stream in)
                   out))

(defun decode-base64-stream-to-sequence (stream &key parser-errors)
  "Read Base64 characters from STREAM and return result of decoding them as a
binary sequence."
  ;; parser-errors are ignored for base64
  (declare (ignore parser-errors))
  (let* ((buffered-size 4096)
         (dstream (make-instance 'qbase64:decode-stream
                                 :underlying-stream stream))
         (output-seq (make-array buffered-size
                                 :element-type '(unsigned-byte 8)
                                 :adjustable t)))
    (loop for cap = (array-dimension output-seq 0)
          for pos = (read-sequence output-seq dstream :start (or pos 0))
          if (>= pos cap)
            do (adjust-array output-seq (+ cap buffered-size))
          else
            do (progn
                 (adjust-array output-seq pos)
                 (return output-seq)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun dump-stream-binary (in out)
  "Write content of IN character stream to OUT binary stream."
  (loop
     for c = (read-char in nil)
     while c
     do (write-byte (char-code c) out)))

(defun decode-string (string encoding &key parser-errors-p)
  (gcase (encoding string-equal)
    (:quoted-printable
     (decode-quoted-printable-string string
                                     :parser-errors parser-errors-p))
    (:base64
     ;; parser-errors-p is unused in base64
     (qbase64:decode-string string))
    (otherwise
     (map '(vector (unsigned-byte 8)) #'char-code string))))

(defun decode-stream-to-sequence (stream encoding &key parser-errors-p)
  (gcase (encoding string-equal)
    (:quoted-printable
     (decode-quoted-printable-stream-to-sequence stream
                                                 :parser-errors parser-errors-p))
    (:base64
     (decode-base64-stream-to-sequence stream
                                       :parser-errors parser-errors-p))
    (otherwise
     (loop
        with output-sequence = (make-array 0 :fill-pointer 0
                                           :element-type '(unsigned-byte 8)
                                           :adjustable t)
        for c = (read-char stream nil)
        while c
        do (vector-push-extend (char-code c) output-sequence)
        finally (return output-sequence)))))

(defun encode-stream (in out encoding)
  (gcase (encoding string-equal)
    (:quoted-printable
     (encode-quoted-printable-stream in out))
    (:base64
     (encode-base64-stream in out))
    (otherwise
     (loop
        for byte = (read-byte in nil)
        while byte
        do (write-char (code-char byte) out)))))

(defun encode-sequence-to-stream (sequence out encoding)
  (gcase (encoding string-equal)
    (:quoted-printable
     (encode-quoted-printable-sequence-to-stream sequence out))
    (:base64
     (encode-base64-sequence-to-stream sequence out))
    (otherwise
     (loop
        for byte across sequence
        do (write-char (code-char byte) out)))))

(defun encode-sequence (sequence encoding)
  (gcase (encoding string-equal)
    (:quoted-printable
     (encode-quoted-printable-sequence sequence))
    (:base64
     (encode-base64-sequence sequence))
    (otherwise
     (map 'string #'code-char sequence))))

;; This is similar to decode-quoted-printable-string but #\_ is used
;; instead of space
(defun decode-quoted-printable-RFC2047-string (string &key (start 0) (end (length string)))
  "Decode a string encoded according to the quoted printable
method of RFC2047 and return a sequence of bytes."
  (declare (optimize (speed 3) (debug 0) (safety 0))
           (type simple-string string))
  (loop
     with output-sequence = (make-array (length string)
                                        :element-type '(unsigned-byte 8)
                                        :fill-pointer 0)
     for i fixnum from start by 1 below end
     for c = (char string i)
     do (case c
          (#\=
           (vector-push-extend (or (parse-hex (char string (1+ i)) (char string (+ 2 i)))
                                   ;; the char code was malformed
                                   #.(char-code #\?))
                               output-sequence)
           (f++ i 2))
          (#\_ (vector-push-extend #.(char-code #\space) output-sequence))
          (otherwise
           (vector-push-extend (char-code c) output-sequence)))
       finally (return output-sequence)))

(defun decode-RFC2047-part (encoding string &key (start 0) (end (length string)))
  "Decode STRING according to RFC2047 and return a sequence of
bytes."
  (gcase (encoding string-equal)
    ("Q" (decode-quoted-printable-RFC2047-string string :start start :end end))
    ("B" (qbase64:decode-string (subseq string start end)))
    (t string)))

(defun parse-RFC2047-text (text)
  "Parse the string TEXT according to RFC2047 rules and return a list
of pairs and strings.  The strings are the bits interposed between the
actually encoded text.  The pairs are composed of: a decoded byte
sequence, a charset string indicating the original coding."
  (loop
     with result = '()
     with previous-end = 0
     for start = (search "=?" text :start2 previous-end)
     while start
     for first-? = (position #\? text :start (+ 2 start))
     while first-?
     for second-? = (position #\? text :start (1+ first-?))
     while second-?
     for end = (search "?=" text :start2 (1+ second-?))
     while end
     do (let ((charset (string-upcase (subseq text (+ 2 start) first-?)))
              (encoding (subseq text (1+ first-?) second-?)))
          (unless (= previous-end start)
            (push (subseq text previous-end start)
                  result))
          (setf previous-end (+ end 2))
          (push (cons (decode-RFC2047-part encoding text :start (1+ second-?) :end end)
                      charset)
                result))
     finally (unless (= previous-end (length text))
               (push (subseq text previous-end (length text))
                     result))
       (return (nreverse result))))

(defun decode-RFC2047 (text)
  "Decode TEXT into a fully decoded string. Whenever a non ASCII part is
  encountered, try to decode it using flexi-streams, otherwise signal an error."
  (flet ((decode-part (part)
           (etypecase part
             (cons (flexi-streams:octets-to-string
                    (car part)
                    :external-format (flexi-streams:make-external-format
                                      ;; TODO(sterni): sanitize charset before interning
                                      (intern (string-upcase (cdr part)) 'keyword))))
             (string part))))
    (apply #'concatenate
           (cons 'string
                 (mapcar #'decode-part (mime:parse-RFC2047-text text))))))
