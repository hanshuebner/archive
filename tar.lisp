;;;; tar.lisp -- reading and writing tar files from Common Lisp

;;; Yes, perfectly good implementations of tar already exist.  However,
;;; there are none for Common Lisp. :)  Actually, the main motivation
;;; behind writing this was to eventually provide a TAR-OP or something
;;; similar for ASDF.  This would make packaging up systems very easy.
;;; Furthermore, something like asdf-install could use this package as
;;; part of its installation routines.
;;;
;;; Implementation notes:
;;;
;;; Tar archives make ugly conflations between characters and bytes, as
;;; is typical of C programs.  This implementation deals strictly with
;;; bytes internally and will only convert to actual strings when the
;;; user requests it.  Hooks are provided for the user to customize the
;;; conversion of byte vectors to strings.  Bind
;;; *BYTEVEC-TO-STRING-CONVERSION-FUNCTION* or
;;; *STRING-TO-BYTEVEC-CONVERSION-FUNCTION* to use your own custom
;;; conversion functions.  The default functions will convert strings as
;;; ASCII (Latin-1, really), which may be good enough for you.
;;;
;;; Bugs almost certainly remain.  In particular, the implementation
;;; cannot yet handle archiving directories, so the equivalent of
;;;
;;;   tar cf foo.tar bar/
;;;
;;; will fail, whereas the equivalent of
;;;
;;;   tar cf foo.tar bar/*
;;;
;;; will work (so long as `bar' does not contain directories, of
;;; course).  Regular files are the only archivable entities at the
;;; moment; attempting to back up your /dev directory with the tools
;;; contained herein will be a futile exercise.
;;;
;;; The implementation only handles ustar archives (POSIX circa 1988 or
;;; so) and does not handle pax archives (POSIX circa 2001 or so).  This
;;; is a shortcoming that I would like to see fixed, but have not yet
;;; examined what would be necessary to do so.  Archive buffer handling
;;; would likely need to be altered somewhat, as the current version is
;;; biased towards handling tar files (fixed records of 512 bytes).

(in-package :archive)


;;; constants and class definitions
(defconstant +tar-n-block-bytes+ 512)
;;; GNU tar makes this configurable, actually.
(defconstant +tar-n-record-blocks+ 20)
(defconstant +tar-n-record-bytes+ (* +tar-n-block-bytes+ +tar-n-record-blocks+))

;;; values for tar's `typeflag' field
(defconstant +tar-regular-file+ #x30)
;;; backwards compatibility
(defconstant +tar-regular-alternate-file+ #x00)
(defconstant +tar-hard-link+ #x31)
(defconstant +tar-symbolic-link+ #x32)
(defconstant +tar-character-device+ #x33)
(defconstant +tar-block-device+ #x34)
(defconstant +tar-directory-file+ #x35)
(defconstant +tar-fifo-device+ #x36)
(defconstant +tar-implementation-specific-file+ #x37)

(defconstant +posix-extended-header+ #x78)
(defconstant +posix-global-header+ #x67)

;;; non-standard typeflags
(defconstant +gnutar-long-link-name+ #x4b)
(defconstant +gnutar-long-name+ #x4c)
(defconstant +gnutar-sparse+ #x53)

(defconstant +ascii-space+ #x20)
(defconstant +ascii-zero+ #x30)
(defconstant +ascii-nine+ #x39)
(defconstant +ascii-a+ #x61)
(defconstant +ascii-z+ #x7a)

(defparameter *tar-magic-vector*
  (coerce `(,@(map 'list #'char-code "ustar") 0)
          '(vector (unsigned-byte 8))))
(defparameter *tar-version-vector*
  (coerce (map 'list #'char-code "00") '(vector (unsigned-byte 8))))

(defclass tar-archive (archive) ())

(defmethod initialize-instance :after ((instance tar-archive) &rest initargs)
  (declare (ignore initargs))
  (initialize-entry-buffer instance +tar-header-length+))

(defun convert-bytevec-to-string (buffer &key (start 0) end)
  (let* ((end (or end
                  (position 0 buffer :start start :end end)
                  (length buffer)))
         (string (make-string (- end start) :element-type 'base-char)))
    (loop for string-index from 0
          for buffer-index from start below end
          do (setf (aref string string-index)
                   (code-char (aref buffer buffer-index)))
          finally (return string))))

(defun convert-string-to-bytevec (string &key (start 0) end)
  (let* ((end (or end (length string)))
         (buffer (make-array (- end start) :element-type '(unsigned-byte 8)
                             :initial-element 0)))
    (loop for string-index from start below end
          for buffer-index from 0
          do (setf (aref buffer buffer-index)
                   (char-code (aref string string-index)))
          finally (return buffer))))

(defvar *bytevec-to-string-conversion-function* #'convert-bytevec-to-string)
(defvar *string-to-bytevec-conversion-function* #'convert-string-to-bytevec)

(defun read-number-from-buffer (buffer &key (start 0) end (radix 10))
  (declare (type (simple-array (unsigned-byte 8) (*)) buffer))
  (declare (type (integer 2 36) radix))
  (let ((end (or (position-if #'(lambda (b)
                                  ;; For BSD tar, a number can end with
                                  ;; a space or a null byte.
                                  (or (= b +ascii-space+) (zerop b)))
                              buffer :start start :end end)
                 end
                 (length buffer))))
    ;; GNU tar permits storing numbers as binary; a binary number is
    ;; indicated by starting the field with #x80.
    (if (= (aref buffer start) #x80)
        (loop for i from (1- end) downto (1+ start)
           for base = 1 then (* base 256)
           sum (* (aref buffer i) base))
        (loop for i from (1- end) downto start
           for base = 1 then (* base radix)
           sum (let ((byte (aref buffer i)))
                 (cond
                   ((<= +ascii-zero+ byte +ascii-nine+)
                    (* base (- byte +ascii-zero+)))
                   ((<= +ascii-a+ byte +ascii-z+)
                    (* base (+ 10 (- byte +ascii-a+))))
                   (t (error "Invalid byte: ~A in ~A"
                             byte (subseq buffer start end)))))))))

(defun write-number-to-buffer (number buffer &key (start 0) end (radix 10) nullp)
  (declare (type (simple-array (unsigned-byte 8) (*)) buffer))
  (declare (type (integer 2 36) radix))
  (let ((end (let ((dend (or end (length buffer))))
               (if nullp
                   (1- dend)
                   dend))))
    (loop for i from (1- end) downto start
          do (multiple-value-bind (quo rem) (truncate number radix)
               (setf number quo)
               (setf (aref buffer i)
                     (cond
                       ((<= 0 rem 9) (+ rem +ascii-zero+))
                       ((<= 10 rem 36) (+ (- rem 10) +ascii-a+))
                       (t (error "Don't know how to encode ~A" rem))))))
    (values)))

(defun read-bytevec-from-buffer (buffer &key (start 0) end nullp)
  (let ((end (if nullp
                 (position 0 buffer :start start :end end)
                 end)))
    (subseq buffer start end)))

;;; translate from tar's awkward name/prefix fields into something sane
(defmethod name ((entry tar-entry))
  (let ((prefix (%prefix entry)))
    (if (or (zerop (length prefix))
            (zerop (aref prefix 0)))    ; no prefix given
        (funcall *bytevec-to-string-conversion-function* (%name entry))
        (funcall *bytevec-to-string-conversion-function*
                 (concatenate '(vector (unsigned-byte 8))
                              prefix (%name entry))))))

(defmethod (setf name) (value (entry tar-entry))
  ;;; FIXME: need to handle `PREFIX' correctly too.
  (setf (%name entry)
        (funcall *string-to-bytevec-conversion-function* value))
  value)

(defmethod print-object ((entry tar-entry) stream)
  (print-unreadable-object (entry stream)
    (format stream "Tar-Entry ~A" (name entry))))

(defmethod entry-regular-file-p ((entry tar-entry))
  (eql (typeflag entry) +tar-regular-file+))

(defmethod entry-directory-p ((entry tar-entry))
  (eql (typeflag entry) +tar-directory-file+))

(defmethod entry-symbolic-link-p ((entry tar-entry))
  (eql (typeflag entry) +tar-symbolic-link+))

(defmethod entry-character-device-p ((entry tar-entry))
  (eql (typeflag entry) +tar-character-device+))

(defmethod entry-block-device-p ((entry tar-entry))
  (eql (typeflag entry) +tar-block-device+))

(defmethod entry-fifo-p ((entry tar-entry))
  (eql (typeflag entry) +tar-fifo-device+))

;;; archives

;;; internal functions of all kinds

(defun round-up-to-tar-block (num)
  (* (ceiling num +tar-n-block-bytes+) +tar-n-block-bytes+))

(defun tar-checksum-guts (block start transform-fun)
  (declare (type (simple-array (unsigned-byte 8) (*)) block))
  (let ((end (+ start +tar-n-block-bytes+))
        (checksum-start (+ start +tar-header-checksum-offset+))
        (checksum-end (+ start +tar-header-checksum-offset+
                         +tar-header-checksum-length+)))
    (loop for i from start below end
          sum (if (or (< i checksum-start) (<= checksum-end i))
                  (funcall transform-fun (aref block i))
                  +ascii-space+))))

(defun compute-checksum-for-tar-header (block start)
  (tar-checksum-guts block start #'identity))

(defun compute-old-checksum-for-tar-header (block start)
  (tar-checksum-guts block start #'(lambda (b) (if (< b 128) b (- b 256)))))

(defun tar-block-checksum-matches-p (block checksum start)
  (let ((sum (compute-checksum-for-tar-header block start)))
    (if (= sum checksum)
        t
        ;; try the older, signed arithmetic way
        (let ((sum (compute-old-checksum-for-tar-header block start)))
          (= sum checksum)))))

(defun null-block-p (block start)
  (declare (type (simple-array (unsigned-byte 8) (*)) block))
  (let ((end (+ start +tar-n-block-bytes+)))
    (loop for i from start below end
          unless (zerop (aref block i))
            do (return-from null-block-p nil)
          finally (return-from null-block-p t))))

(defparameter *modefuns-to-typeflags*
  #+use-sb-posix
  (list (cons #'sb-posix::s-isreg +tar-regular-file+)
	(cons #'sb-posix::s-isdir +tar-directory-file+)
	(cons #'sb-posix::s-ischr +tar-character-device+)
	(cons #'sb-posix::s-isblk +tar-block-device+)
	(cons #'sb-posix::s-isfifo +tar-fifo-device+)
	(cons #'sb-posix::s-islnk +tar-symbolic-link+))
  #-use-sb-posix
  (list (cons 'isreg +tar-regular-file+)
	(cons 'isdir +tar-directory-file+)
	(cons 'ischarfile +tar-character-device+)
	(cons 'isblockfile +tar-block-device+)
	(cons 'isfifo +tar-fifo-device+)
	(cons 'islink +tar-symbolic-link+)))

(defun typeflag-for-mode (mode)
  (loop for (modefun . typeflag) in *modefuns-to-typeflags*
        when (funcall modefun mode)
        do (return-from typeflag-for-mode typeflag)
        finally (error "No typeflag found for mode ~A" mode)))

(defmethod create-entry-from-pathname ((archive tar-archive) pathname &key entry-name)
  (let ((entry-name (or entry-name
                        (namestring pathname))))
    ;; FIXME: figure out how to properly use the prefix field so we can
    ;; ditch this check.
    (when (> (length entry-name) (1- +tar-header-%name-length+))
      (error "~A has too many characters in it." pathname))
    (let ((stat (stat pathname)))
      (make-instance 'tar-entry
                     :pathname pathname
                     :%name (funcall *string-to-bytevec-conversion-function*
                                     entry-name)
                     :mode (logand +permissions-mask+
                                   (stat-mode stat))
                     :typeflag (typeflag-for-mode (stat-mode stat))
                     :uid (stat-uid stat)
                     :gid (stat-gid stat)
                     :size (stat-size stat)
                     :mtime (stat-mtime stat)))))

(defmethod add-entry ((archive tar-archive)
                      entry-name
                      contents
                      &rest args
                      &key (mode +permissions-mask+ mode-present-p)
                           (typeflag +tar-regular-file+ typeflag-present-p)
                           (uid 0 uid-present-p)
                           (gid 0 gid-present-p)
                           (mtime (- (get-universal-time) +universal-time-offset+) mtime-present-p))
  (let (entry)
    (flet
        ((make-entry (&rest args-from-pathname &key &allow-other-keys)
           (setf entry (apply #'make-instance
                              'tar-entry
                              :%name (funcall *string-to-bytevec-conversion-function* entry-name)
                              ;; This is not pretty: We want to be
                              ;; able to have the caller specify any
                              ;; of mode/typeflag/uid/gid/mtime, fall
                              ;; back to what the real file has for
                              ;; these attribute (if a file is
                              ;; written) and then default to the
                              ;; defaults provided in this functions'
                              ;; header.
                              (append args
                                      (and mode-present-p (list :mode mode))
                                      (and typeflag-present-p (list :typeflag typeflag))
                                      (and uid-present-p (list :uid uid))
                                      (and gid-present-p (list :gid gid))
                                      (and mtime-present-p (list :mtime mtime))
                                      args-from-pathname
                                      (list :mode mode
                                            :typeflag typeflag
                                            :uid uid
                                            :gid gid
                                            :mtime mtime)))))
         (write-entry (stream)
           (setf (slot-value entry 'size)
                 (or (file-length stream)
                     (error "cannot determine contents size of stream ~A for archive entry creation" stream)))
           (write-entry-to-archive archive entry :stream stream)))
      (etypecase contents
        #+allegro
        (string
         (make-entry)
         (let ((buffer (funcall *string-to-bytevec-conversion-function* contents)))
           (excl:with-input-from-buffer (stream buffer)
             (write-entry stream))))
        (stream
         (make-entry)
         (write-entry contents))
        (pathname
         (let ((stat (stat contents)))
           (make-entry :mode (logand +permissions-mask+
                                     (stat-mode stat))
                       :typeflag (typeflag-for-mode (stat-mode stat))
                       :uid (stat-uid stat)
                       :gid (stat-gid stat)
                       :mtime (stat-mtime stat)))
         (with-open-file (stream contents :element-type '(unsigned-byte 8))
           (write-entry stream)))))))

(defmethod write-entry-to-buffer ((entry tar-entry) buffer &optional (start 0))
  (declare (type (simple-array (unsigned-byte 8) (*)) buffer))
  ;; ensure a clean slate
  (assert (<= (+ start +tar-n-block-bytes+) (length buffer)))
  (fill buffer 0 :start start :end (+ start +tar-n-block-bytes+))

  (tar-header-write-%name-to-buffer buffer start (%name entry))
  (tar-header-write-mode-to-buffer buffer start (mode entry))
  (tar-header-write-uid-to-buffer buffer start (uid entry))
  (tar-header-write-gid-to-buffer buffer start (gid entry))
  (tar-header-write-magic-to-buffer buffer start *tar-magic-vector*)
  (tar-header-write-version-to-buffer buffer start *tar-version-vector*)
  (tar-header-write-size-to-buffer buffer start (size entry))
  (tar-header-write-mtime-to-buffer buffer start (mtime entry))
  (tar-header-write-typeflag-to-buffer buffer start (typeflag entry))

  ;; the checksum is written in a peculiar fashion
  (let* ((checksum (compute-checksum-for-tar-header buffer start)))
    (write-number-to-buffer checksum buffer
                            :start (+ start +tar-header-checksum-offset+)
                            :end (+ start +tar-header-checksum-offset+ +tar-header-checksum-length+ -2)
                            :radix 8)
    ;; terminated with a NULL and then a space (!?)
    (setf (aref buffer (+ start +tar-header-checksum-offset+ 6)) 0
          (aref buffer (+ start +tar-header-checksum-offset+ 7)) +ascii-space+)))

(defun read-tar-entry-from-buffer (buffer &key (start 0))
  (with-extracted-fields (tar-header buffer start
                                     %name mode mtime size checksum uid
                                     gid magic typeflag uname gname)
    (if (tar-block-checksum-matches-p buffer checksum start)
        (make-instance 'tar-entry
                       :%name %name
                       :mode mode
                       :mtime mtime
                       :size size
                       :checksum checksum
                       :uid uid
                       :gid gid
                       :magic magic
                       :typeflag typeflag
                       :uname uname
                       :gname gname)
        (error "Invalid tar entry header data!"))))


;;; buffering data from the archive's stream
;;;
;;; we want to do a couple of different things with buffered data:
;;;
;;; * read entries from the buffered data--requires a specific amount
;;;   of data at read time.  the data required for this operation is
;;;   discarded immediately after use.
;;; * read variable-sized data from the buffered data or stream--
;;;   requires a specific amount of data at read time.  this data must
;;;   persist after reading it from the buffer--displaced arrays could
;;;   not be used for this purpose.
;;; * transfer data from the archive's stream/data to another stream
;;;   (i.e. processing entry data).

(defmethod read-entry-from-archive ((archive tar-archive))
  (let ((entry-block (read-entry-block archive)))
    (if (null-block-p entry-block 0)
        nil
        (let ((entry (read-tar-entry-from-buffer entry-block :start 0)))
          (cond
            ((= (typeflag entry) +gnutar-long-name+)
             (let ((real-name (read-data-block archive (size entry)
                                               #'round-up-to-tar-block))
                   (entry (read-entry-from-archive archive)))
               (setf (%name entry) real-name)
               entry))
            ((= (typeflag entry) +gnutar-long-link-name+)
             (let ((real-link-name (read-data-block archive (size entry)
                                                    #'round-up-to-tar-block))
                   (entry (read-entry-from-archive archive)))
               (setf (linkname entry) real-link-name)
               entry))
            ((or (= (typeflag entry) +tar-regular-file+)
                 (= (typeflag entry) +tar-directory-file+))
             entry)
            ((= (typeflag entry) +posix-extended-header+)
             (error "Don't understand POSIX extended header entry"))
            ((= (typeflag entry) +posix-global-header+)
             ;; FIXME: We should make the information from this
             ;; available to the user.  At the moment, however, most
             ;; global headers seen in the wild are git stashing a
             ;; "comment=<sha1>".  So just ignore them for now.
             (let ((global-header (read-data-block archive (size entry)
                                                   #'round-up-to-tar-block)))
               (declare (ignore global-header))
               (read-entry-from-archive archive)))
            ((= (typeflag entry) +gnutar-sparse+)
             (let (sparse-descriptors)
               (with-extracted-fields (sparse-file-header entry-block 0
                                                          sp isextended realsize)
                 (flet
                     ((interpret-entry (offset size)
                        (if (zerop size)
                            (when (plusp offset)
                              (assert (= offset realsize)))
                            (push (cons offset size) sparse-descriptors))))
                   (dotimes (i 4)
                     (with-extracted-fields (sparse-entry sp (* i 24)
                                                          offset size)
                       (interpret-entry offset size)))
                   (when (plusp isextended)
                     (loop
                        (let ((extension-block (read-data-block archive +sparse-extension-header-length+ #'round-up-to-tar-block)))
                          (with-extracted-fields (sparse-extension-header extension-block 0
                                                                          sp isextended)
                            (dotimes (i 21)
                              (with-extracted-fields (sparse-entry sp (* i 24)
                                                                   offset size)
                                (interpret-entry offset size)))
                            (unless (plusp isextended)
                              (return))))))
                   (change-class entry 'sparse-tar-entry
                                 :sparse-descriptors (nreverse sparse-descriptors)
                                 :file-size realsize)))))
            (t
             (error "Can't understand typeflag: ~A" (typeflag entry))))))))

(defun extract-sparse-entry (archive entry pathname)
  (with-open-file (out pathname
                       :direction :output
                       :if-exists :supersede
                       :element-type '(unsigned-byte 8))
    (dolist (sparse-descriptor (sparse-descriptors entry))
      (excl.osi:os-ftruncate out (file-size entry))
      (destructuring-bind (offset . size) sparse-descriptor
        (format t "extracting ~A bytes to offset ~A~%" size offset)
        (file-position out offset)
        (let* ((n-bytes-remaining size)
               (rounded-n-bytes-remaining (round-up-to-tar-block size))
               (archive-stream (archive-stream archive))
               (buffer (file-buffer archive)))
          (loop
             (let ((bytes-read (read-sequence buffer archive-stream
                                              :start 0
                                              :end (min (length buffer)
                                                        rounded-n-bytes-remaining))))
               (assert (plusp bytes-read))
               (assert (not (minusp n-bytes-remaining)))
               (decf rounded-n-bytes-remaining bytes-read)
               (write-sequence buffer out
                               :start 0
                               :end (min n-bytes-remaining bytes-read))
               (decf n-bytes-remaining bytes-read))
             (unless (plusp rounded-n-bytes-remaining)
               (return))))))
    ;; truncate file again to make sure that original size is
    ;; matched even if more data has been written due to blocking
    (excl.osi:os-ftruncate out (file-size entry)))
  ;; indicate that we've already discarded the data
  (setf (n-bytes-remaining (slot-value entry 'stream)) 0)
  (setf (data-discarded-p entry) t))
  
            
;;; FIXME: must add permissions handling, mtime, etc.  maybe those should
;;; be specified by flags or somesuch?
(defmethod extract-entry ((archive tar-archive) (entry tar-entry) &key pathname)
  (let ((pathname (or pathname (entry-pathname entry))))
    (cond
      ((= (typeflag entry) +tar-directory-file+)
       (ensure-directories-exist pathname))
      ((= (typeflag entry) +tar-regular-file+)
       (ensure-directories-exist pathname)
       (with-open-file (stream pathname
                               :direction :output
                               :if-exists :supersede
                               :element-type '(unsigned-byte 8))
         (transfer-entry-data-to-stream archive entry stream)))
      ((= (typeflag entry) +gnutar-sparse+)
       (ensure-directories-exist pathname)
       (extract-sparse-entry archive entry pathname))
      (t
       (error "Don't know how to extract a type ~A tar entry yet" 
              (typeflag entry))))))

(defmethod transfer-entry-data-to-stream ((archive tar-archive)
                                          (entry tar-entry)
                                          stream)
  (transfer-entry-data-to-stream* archive entry stream #'round-up-to-tar-block))

(defmethod discard-entry ((archive tar-archive) (entry tar-entry))
  (discard-unused-entry-data archive entry #'round-up-to-tar-block))


(defun transfer-stream-to-archive (archive stream)
  (with-slots (file-buffer (archive-stream stream)) archive
    (do ((bytes-read (read-sequence file-buffer stream)
                     (read-sequence file-buffer stream))
         (total-bytes 0 (+ total-bytes bytes-read))
         (length (length file-buffer)))
        ((< bytes-read length)
         (let* ((rounded-length (round-up-to-tar-block bytes-read))
                (total-bytes (+ total-bytes bytes-read))
                (rounded-bytes (round-up-to-tar-block total-bytes )))
           (fill file-buffer 0 :start bytes-read :end rounded-length)
           (incf (bytes-output archive) (+ rounded-bytes +tar-header-length+))
           (write-sequence file-buffer archive-stream
                           :end rounded-length)
           (values)))
      (write-sequence file-buffer archive-stream))))

;;; writing entries in various guises
(defmethod write-entry-to-archive :before ((archive tar-archive)
                                           (archive-entry tar-entry)
                                           &key stream)
  (declare (ignore stream))
  (unless (= (typeflag archive-entry) +tar-regular-file+)
    (error "Don't know how to write entries of type ~A yet"
           (typeflag archive-entry))))

(defmethod finalize-archive ((archive tar-archive))
  (let ((null-block (make-array +tar-n-record-bytes+
                                :element-type '(unsigned-byte 8)
                                :initial-element 0)))
    (declare (dynamic-extent null-block))
    (write-sequence null-block (archive-stream archive)
                    :end (* +tar-header-length+ 2))
    (incf (bytes-output archive) 1024)
    (assert (zerop (mod (bytes-output archive) +tar-header-length+)))
    (multiple-value-bind (multiplier bytes-remaining)
        (ceiling (bytes-output archive) +tar-n-record-bytes+)
      (declare (ignore multiplier))
      (write-sequence null-block (archive-stream archive)
                      :end (- bytes-remaining))
      (values))))

(defun create-tar-file (pathname)
  (with-open-archive (archive pathname :direction :output
                              :if-exists :supersede)
    (add-entry archive "hello" "text from string")
    (add-entry archive "passwd" #P"/etc/passwd")
    (finalize-archive archive)))
