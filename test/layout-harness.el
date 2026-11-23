;;; layout-harness.el --- Helpers for test_layout.py  -*- lexical-binding: t; -*-

;;; Commentary:

;; Used by test/test_layout.py, which runs Emacs in batch mode.

;;; Code:

(require 'beamer-gui)
(defun layout-compile (doc dir)
  (let ((tmp (make-temp-file "inv" t)) result)
    (beamer-gui--compile doc dir tmp (lambda (p) (setq result p)) (lambda (l) (setq result (list l))))
    (while (not result) (accept-process-output nil 0.1))
    (if (stringp result) (cons result tmp) (error "LaTeX failed %S" result))))
(defun layout-move (file name dx &optional dy)
  (with-current-buffer (find-file-noselect file)
    (goto-char (point-min)) (search-forward "\\begin{frame}")
    (let* ((b (beamer-gui-frame-bounds))
           (parts (beamer-gui--frame-parts (car b)))
           (res (layout-compile (beamer-gui-measure-document (nth 0 parts) (nth 1 parts) (nth 2 parts) nil)
                           (file-name-directory file)))
           (meas (beamer-gui-measurements (expand-file-name "frame.bgpos" (cdr res))))
           (model (beamer-gui-frame-model (car b) (cdr b)))
           (items (mapcar (lambda (i)
                            (let ((box (append (plist-get i :box) nil)))
                              (append (list :box (if (equal (plist-get i :name) name)
                                                     (list (+ (nth 0 box) dx) (+ (nth 1 box) (or dy 0)) (nth 2 box) (nth 3 box))
                                                   box)
                                            :box0 box)
                                      i)))
                          (beamer-gui-gui-items model meas))))
      (beamer-gui-apply-items (car b) (cdr b) items meas)
      (save-buffer))))
(defun layout-write (file valign body)
  (with-temp-file file
    (insert "\\documentclass{beamer}\n\\usepackage{tcolorbox}\n" beamer-gui-preamble
            "\\begin{document}\n\\begin{frame}[" valign "]{Flow}\n" body "\\end{frame}\n\\end{document}\n")))

(provide 'layout-harness)
;;; layout-harness.el ends here

(defun layout--frame (n)
  "Move to the Nth frame (from 1) of the buffer; return its bounds."
  (goto-char (point-min))
  (dotimes (_ n) (re-search-forward beamer-gui--frame-begin-regexp))
  (beamer-gui-frame-bounds))

(defun layout--with-definitions (file function)
  "Call FUNCTION in FILE's buffer with the document's definitions bound."
  (with-current-buffer (find-file-noselect file)
    (let* ((dir (file-name-directory file))
           (preamble (save-excursion
                       (goto-char (point-min))
                       (re-search-forward beamer-gui--document-begin-regexp)
                       (buffer-substring-no-properties (point-min) (point))))
           (beamer-gui--document-definitions
            (beamer-gui-document-definitions (beamer-gui--preamble-sources preamble dir))))
      (funcall function))))

(defun layout-elements (file out)
  "Write to OUT, as JSON, the movable elements of each frame of FILE."
  (layout--with-definitions
   file
   (lambda ()
     (let ((n 0) frames)
       (goto-char (point-min))
       (while (re-search-forward beamer-gui--frame-begin-regexp nil t)
         (cl-incf n)
         (let* ((b (beamer-gui-frame-bounds))
                (m (beamer-gui-frame-model (car b) (cdr b))))
           (push (list :frame n
                       :elements (vconcat (mapcar (lambda (e) (plist-get e :id))
                                                  (plist-get m :elements))))
                 frames)
           (goto-char (cdr b))))
       (with-temp-file out (insert (json-serialize (vconcat (nreverse frames)))))))))

(defun layout-move-in-frame (file n id dx &optional dy)
  "Move element ID of the Nth frame of FILE by DX, DY page fractions; save."
  (layout--with-definitions
   file
   (lambda ()
     (let* ((b (layout--frame n))
            (parts (beamer-gui--frame-parts (car b)))
            (res (layout-compile (beamer-gui-measure-document
                                  (nth 0 parts) (nth 1 parts) (nth 2 parts) nil)
                                 (file-name-directory file)))
            (meas (beamer-gui-measurements (expand-file-name "frame.bgpos" (cdr res))))
            (items (mapcar (lambda (i)
                             (let ((box (append (plist-get i :box) nil)))
                               (append (list :box (if (equal (plist-get i :id) id)
                                                      (list (+ (nth 0 box) dx)
                                                            (+ (nth 1 box) (or dy 0))
                                                            (nth 2 box) (nth 3 box))
                                                    box)
                                             :box0 box)
                                       i)))
                           (beamer-gui-gui-items (beamer-gui-frame-model (car b) (cdr b)) meas))))
       (unless (cl-find id items :key (lambda (i) (plist-get i :id)) :test #'equal)
         (error "No element %s in frame %d" id n))
       (beamer-gui-apply-items (car b) (cdr b) items meas)
       (save-buffer)))))
