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
