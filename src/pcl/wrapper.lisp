;;;; Bits and pieces of the wrapper machninery. This used to live in cache.lisp,
;;;; but doesn't really logically belong there.

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.

;;;; This software is derived from software originally released by Xerox
;;;; Corporation. Copyright and release statements follow. Later modifications
;;;; to the software are in the public domain and are provided with
;;;; absolutely no warranty. See the COPYING and CREDITS files for more
;;;; information.

;;;; copyright information from original PCL sources:
;;;;
;;;; Copyright (c) 1985, 1986, 1987, 1988, 1989, 1990 Xerox Corporation.
;;;; All rights reserved.
;;;;
;;;; Use and copying of this software and preparation of derivative works based
;;;; upon this software are permitted. Any distribution of this software or
;;;; derivative works must comply with all applicable United States export
;;;; control laws.
;;;;
;;;; This software is made available AS IS, and Xerox Corporation makes no
;;;; warranty about the software, its performance or its conformity to any
;;;; specification.

(in-package "SB-PCL")

(defmacro wrapper-class (wrapper)
  `(classoid-pcl-class (layout-classoid ,wrapper)))
(defmacro wrapper-no-of-instance-slots (wrapper)
  `(layout-length ,wrapper))

;;; This is called in BRAID when we are making wrappers for classes
;;; whose slots are not initialized yet, and which may be built-in
;;; classes. We pass in the class name in addition to the class.
(defun boot-make-wrapper (length name &optional class)
  (let ((found (find-classoid name nil)))
    (cond
     (found
      (unless (classoid-pcl-class found)
        (setf (classoid-pcl-class found) class))
      (aver (eq (classoid-pcl-class found) class))
      (let ((layout (classoid-layout found)))
        (aver layout)
        layout))
     (t
      (make-wrapper-internal
       :length length
       :classoid (make-standard-classoid
                  :name name :pcl-class class))))))

;;; The following variable may be set to a STANDARD-CLASS that has
;;; already been created by the lisp code and which is to be redefined
;;; by PCL. This allows STANDARD-CLASSes to be defined and used for
;;; type testing and dispatch before PCL is loaded.
(defvar *pcl-class-boot* nil)

;;; In SBCL, as in CMU CL, the layouts (a.k.a wrappers) for built-in
;;; and structure classes already exist when PCL is initialized, so we
;;; don't necessarily always make a wrapper. Also, we help maintain
;;; the mapping between CL:CLASS and SB-KERNEL:CLASSOID objects.
(defun make-wrapper (length class)
  (cond
    ((or (typep class 'std-class)
         (typep class 'forward-referenced-class))
     (make-wrapper-internal
      :length length
      :classoid
      (let ((owrap (class-wrapper class)))
        (cond (owrap
               (layout-classoid owrap))
              ((or (*subtypep (class-of class) *the-class-standard-class*)
                   (*subtypep (class-of class) *the-class-funcallable-standard-class*)
                   (typep class 'forward-referenced-class))
               (cond ((and *pcl-class-boot*
                           (eq (slot-value class 'name) *pcl-class-boot*))
                      (let ((found (find-classoid
                                    (slot-value class 'name))))
                        (unless (classoid-pcl-class found)
                          (setf (classoid-pcl-class found) class))
                        (aver (eq (classoid-pcl-class found) class))
                        found))
                     (t
                      (let ((name (slot-value class 'name)))
                        (make-standard-classoid :pcl-class class
                                                :name (and (symbolp name) name))))))
              (t
               (bug "Got to T branch in ~S" 'make-wrapper))))))
    (t
     (let* ((found (find-classoid (slot-value class 'name)))
            (layout (classoid-layout found)))
       (unless (classoid-pcl-class found)
         (setf (classoid-pcl-class found) class))
       (aver (eq (classoid-pcl-class found) class))
       (aver layout)
       layout))))

(declaim (inline wrapper-class*))
(defun wrapper-class* (wrapper)
  (or (wrapper-class wrapper)
      (ensure-non-standard-class
       (classoid-name (layout-classoid wrapper)))))

;;; The wrapper cache machinery provides general mechanism for
;;; trapping on the next access to any instance of a given class. This
;;; mechanism is used to implement the updating of instances when the
;;; class is redefined (MAKE-INSTANCES-OBSOLETE). The same mechanism
;;; is also used to update generic function caches when there is a
;;; change to the superclasses of a class.
;;;
;;; Basically, a given wrapper can be valid or invalid. If it is
;;; invalid, it means that any attempt to do a wrapper cache lookup
;;; using the wrapper should trap. Also, methods on
;;; SLOT-VALUE-USING-CLASS check the wrapper validity as well. This is
;;; done by calling CHECK-WRAPPER-VALIDITY.

(declaim (inline invalid-wrapper-p))
(defun invalid-wrapper-p (wrapper)
  (not (null (layout-invalid wrapper))))

;;; We only use this inside INVALIDATE-WRAPPER.
(defvar *previous-nwrappers* (make-hash-table))

;;; We always call this inside WITH-PCL-LOCK.
(defun invalidate-wrapper (owrapper state nwrapper)
  (aver (member state '(:flush :obsolete) :test #'eq))
  (let ((new-previous ()))
    ;; First off, a previous call to INVALIDATE-WRAPPER may have
    ;; recorded OWRAPPER as an NWRAPPER to update to. Since OWRAPPER
    ;; is about to be invalid, it no longer makes sense to update to
    ;; it.
    ;;
    ;; We go back and change the previously invalidated wrappers so
    ;; that they will now update directly to NWRAPPER. This
    ;; corresponds to a kind of transitivity of wrapper updates.
    (dolist (previous (gethash owrapper *previous-nwrappers*))
      (when (eq state :obsolete)
        (setf (car previous) :obsolete))
      (setf (cadr previous) nwrapper)
      (push previous new-previous))

    ;; FIXME: We are here inside PCL lock, but might someone be
    ;; accessing the wrapper at the same time from outside the lock?
    ;; Can it matter that they get 0 from one slot and a valid value
    ;; from another?
    (dotimes (i layout-clos-hash-length)
      (setf (layout-clos-hash owrapper i) 0))

    ;; FIXME: We could save a whopping cons by using (STATE . WRAPPER)
    ;; instead
    (push (setf (layout-invalid owrapper) (list state nwrapper))
          new-previous)

    (remhash owrapper *previous-nwrappers*)
    (setf (gethash nwrapper *previous-nwrappers*) new-previous)))

(defun check-wrapper-validity (instance)
  (let* ((owrapper (wrapper-of instance))
         (state (layout-invalid owrapper)))
    (aver (not (eq state :uninitialized)))
    (etypecase state
      (null owrapper)
      ;; FIXME: I can't help thinking that, while this does cure the
      ;; symptoms observed from some class redefinitions, this isn't
      ;; the place to be doing this flushing.  Nevertheless...  --
      ;; CSR, 2003-05-31
      ;;
      ;; CMUCL comment:
      ;;    We assume in this case, that the :INVALID is from a
      ;;    previous call to REGISTER-LAYOUT for a superclass of
      ;;    INSTANCE's class.  See also the comment above
      ;;    FORCE-CACHE-FLUSHES.  Paul Dietz has test cases for this.
      ((member t)
       (force-cache-flushes (class-of instance))
       (check-wrapper-validity instance))
      (cons
       (ecase (car state)
         (:flush
          (flush-cache-trap owrapper (cadr state) instance))
         (:obsolete
          (obsolete-instance-trap owrapper (cadr state) instance)))))))

(declaim (inline check-obsolete-instance))
(defun check-obsolete-instance (instance)
  (when (invalid-wrapper-p (layout-of instance))
    (check-wrapper-validity instance)))

;;;  NIL: means nothing so far, no actual arg info has NILs in the
;;;  metatype
;;;
;;;  CLASS: seen all sorts of metaclasses (specifically, more than one
;;;  of the next 5 values) or else have seen something which doesn't
;;;  fall into a single category (SLOT-INSTANCE, FORWARD).
;;;
;;;  T: means everything so far is the class T
;;;  STANDARD-INSTANCE: seen only standard classes
;;;  BUILT-IN-INSTANCE: seen only built in classes
;;;  STRUCTURE-INSTANCE: seen only structure classes
;;;  CONDITION-INSTANCE: seen only condition classes
(defun raise-metatype (metatype new-specializer)
  (let ((slot      (find-class 'slot-class))
        (standard  (find-class 'standard-class))
        (fsc       (find-class 'funcallable-standard-class))
        (condition (find-class 'condition-class))
        (structure (find-class 'structure-class))
        (built-in  (find-class 'built-in-class))
        (frc       (find-class 'forward-referenced-class)))
    (flet ((specializer->metatype (x)
             (let ((meta-specializer
                     (if (eq *boot-state* 'complete)
                         (class-of (specializer-class x))
                         (class-of x))))
               (cond
                 ((eq x *the-class-t*) t)
                 ((*subtypep meta-specializer standard) 'standard-instance)
                 ((*subtypep meta-specializer fsc) 'standard-instance)
                 ((*subtypep meta-specializer condition) 'condition-instance)
                 ((*subtypep meta-specializer structure) 'structure-instance)
                 ((*subtypep meta-specializer built-in) 'built-in-instance)
                 ((*subtypep meta-specializer slot) 'slot-instance)
                 ((*subtypep meta-specializer frc) 'forward)
                 (t (error "~@<PCL cannot handle the specializer ~S ~
                            (meta-specializer ~S).~@:>"
                           new-specializer meta-specializer))))))
      ;; We implement the following table. The notation is
      ;; that X and Y are distinct meta specializer names.
      ;;
      ;;    NIL    <anything>    ===>  <anything>
      ;;    X      X             ===>  X
      ;;    X      Y             ===>  CLASS
      (let ((new-metatype (specializer->metatype new-specializer)))
        (cond ((eq new-metatype 'slot-instance) 'class)
              ((eq new-metatype 'forward) 'class)
              ((null metatype) new-metatype)
              ((eq metatype new-metatype) new-metatype)
              (t 'class))))))

(defmacro with-dfun-wrappers ((args metatypes)
                              (dfun-wrappers invalid-wrapper-p
                                             &optional wrappers classes types)
                              invalid-arguments-form
                              &body body)
  `(let* ((args-tail ,args) (,invalid-wrapper-p nil) (invalid-arguments-p nil)
          (,dfun-wrappers nil) (dfun-wrappers-tail nil)
          ,@(when wrappers
              `((wrappers-rev nil) (types-rev nil) (classes-rev nil))))
     (dolist (mt ,metatypes)
       (unless args-tail
         (setq invalid-arguments-p t)
         (return nil))
       (let* ((arg (pop args-tail))
              (wrapper nil)
              ,@(when wrappers
                  `((class *the-class-t*)
                    (type t))))
         (unless (eq mt t)
           (setq wrapper (wrapper-of arg))
           (when (invalid-wrapper-p wrapper)
             (setq ,invalid-wrapper-p t)
             (setq wrapper (check-wrapper-validity arg)))
           (cond ((null ,dfun-wrappers)
                  (setq ,dfun-wrappers wrapper))
                 ((not (consp ,dfun-wrappers))
                  (setq dfun-wrappers-tail (list wrapper))
                  (setq ,dfun-wrappers (cons ,dfun-wrappers dfun-wrappers-tail)))
                 (t
                  (let ((new-dfun-wrappers-tail (list wrapper)))
                    (setf (cdr dfun-wrappers-tail) new-dfun-wrappers-tail)
                    (setf dfun-wrappers-tail new-dfun-wrappers-tail))))
           ,@(when wrappers
               `((setq class (wrapper-class* wrapper))
                 (setq type `(class-eq ,class)))))
         ,@(when wrappers
             `((push wrapper wrappers-rev)
               (push class classes-rev)
               (push type types-rev)))))
     (if invalid-arguments-p
         ,invalid-arguments-form
         (let* (,@(when wrappers
                    `((,wrappers (nreverse wrappers-rev))
                      (,classes (nreverse classes-rev))
                      (,types (mapcar (lambda (class)
                                        `(class-eq ,class))
                                      ,classes)))))
           ,@body))))