;;; fuzz-harness.el --- Random edits for fuzz.py  -*- lexical-binding: t; -*-

;;; Commentary:

;; `fuzz-step' measures the first frame of a file, makes random edits
;; as a user would in the GUI, applies them, saves, and writes what it
;; did to a JSON file for fuzz.py to check.

;;; Code:

(require 'beamer-gui)

(defun fuzz-compile (doc dir)
  "Compile DOC in DIR synchronously; return (PDF . OUTPUT-DIR) or signal."
  (let ((tmp (make-temp-file "fuzz" t)) result)
    (beamer-gui--compile doc dir tmp (lambda (p) (setq result p))
                         (lambda (l) (setq result (list l))))
    (while (not result) (accept-process-output nil 0.05))
    (if (stringp result) (cons result tmp) (error "LaTeX failed: %s" (car result)))))

(defun fuzz-random (lo hi)
  "Return a random float between LO and HI."
  (+ lo (* (- hi lo) (/ (random 100000) 100000.0))))

(defun fuzz-pick (list)
  "Return a random element of LIST."
  (nth (random (length list)) list))

(defun fuzz-step (file seed out &optional noop)
  "Edit the first frame of FILE randomly with SEED; describe it in OUT.
With NOOP, send the items back unchanged."
  (random (format "%s" seed))
  (with-current-buffer (find-file-noselect file)
    (goto-char (point-min))
    (re-search-forward beamer-gui--frame-begin-regexp)
    (let* ((b (beamer-gui-frame-bounds))
           (parts (beamer-gui--frame-parts (car b)))
           (res (fuzz-compile (beamer-gui-measure-document
                               (nth 0 parts) (nth 1 parts) (nth 2 parts) '("red" "blue"))
                              (file-name-directory file)))
           (meas (beamer-gui-measurements (expand-file-name "frame.bgpos" (cdr res))))
           (model (beamer-gui-frame-model (car b) (cdr b)))
           (items (beamer-gui-gui-items model meas))
           (moved nil) (n-new 0) (background nil))
      (unless noop
        (setq items
              (delq nil
                    (mapcar
                     (lambda (i)
                       (let* ((kind (plist-get i :kind))
                              (box (append (plist-get i :box) nil))
                              (item (if box (append (list :box0 box :box box) i) i)))
                         (cond
                          ;; Elements of the text: sometimes move, sometimes resize.
                          ((and box (< (random 100) 45))
                           (let* ((dx (fuzz-random -0.12 0.12)) (dy (fuzz-random -0.1 0.1))
                                  (mode (plist-get i :resize))
                                  (f (if (and (member mode '("aspect" "width")) (< (random 100) 30))
                                         (fuzz-random 0.7 1.3) 1.0))
                                  (new (list (+ (nth 0 box) dx) (+ (nth 1 box) dy)
                                             (* (nth 2 box) f)
                                             (* (nth 3 box) (if (equal mode "aspect") f 1)))))
                             (push (list :id (plist-get i :id) :kind kind
                                         :name (plist-get i :name) :dx dx :dy dy :factor f
                                         :box0 (vconcat box))
                                   moved)
                             (plist-put (copy-sequence item) :box new)))
                          ;; Drawn shapes: sometimes deleted or restyled.
                          ((and (member kind '("arrow" "ellipse" "rect" "text" "image"))
                                (< (random 100) 20))
                           nil)
                          ((and (member kind '("arrow" "ellipse" "rect")) (< (random 100) 30))
                           (plist-put (copy-sequence item) :opts
                                      (fuzz-pick '("draw=blue, very thick" "dashed, draw=red"
                                                   "draw=blue, fill=red, fill opacity=0.3"
                                                   "" "line cap=round, thin"))))
                          (t item))))
                     items)))
        (dotimes (_ (random 3))
          (let ((id (format "fz%d" (cl-incf n-new)))
                (x (fuzz-random 0.05 0.7)) (y (fuzz-random 0.05 0.7)))
            (push (pcase (random 4)
                    (0 (list :kind "arrow" :id id :x1 x :y1 y :x2 (+ x 0.1) :y2 (+ y 0.15)
                             :opts (fuzz-pick '("" "draw=blue, bend left=30" "<->, thin"))))
                    (1 (list :kind "ellipse" :id id :x x :y y :w 0.1 :h 0.05 :opts "draw=red"))
                    (2 (list :kind "rect" :id id :x x :y y :w 0.1 :h 0.05
                             :opts "draw=blue, fill=red, fill opacity=0.2"))
                    (3 (list :kind "text" :id id :x x :y y :w 0.2 :opts "text=blue"
                             :text (fuzz-pick '("Fuzz {text} $x^2$" "Two\\\\lines" "50\\% off")))))
                  items)))
        (when (< (random 100) 25)
          (setq background (fuzz-pick '((:color "red!10" :image "") (:color "" :image "")
                                        (:color "blue!5" :image "example-image-a.pdf"))))))
      (let ((before (buffer-string)) changed)
        (beamer-gui-apply-items (car b) (cdr b) items meas background)
        (save-buffer)
        (setq changed (not (equal before (buffer-string))))
        (with-temp-file out
          (insert (json-serialize
                   (list :moved (vconcat moved)
                         :changed (if changed t :false)
                         :paper (vconcat (plist-get meas :paper))))))))))

(provide 'fuzz-harness)
;;; fuzz-harness.el ends here

(defun fuzz--measure (file)
  "Measure the first frame of FILE; return (BOUNDS MEASUREMENTS PDF)."
  (with-current-buffer (find-file-noselect file)
    (goto-char (point-min))
    (re-search-forward beamer-gui--frame-begin-regexp)
    (let* ((b (beamer-gui-frame-bounds))
           (parts (beamer-gui--frame-parts (car b)))
           (preamble (nth 0 parts))
           (res (fuzz-compile (beamer-gui-measure-document
                               preamble (nth 1 parts) (nth 2 parts)
                               (beamer-gui-document-colors preamble (file-name-directory file)))
                              (file-name-directory file))))
      (list b (beamer-gui-measurements (expand-file-name "frame.bgpos" (cdr res))) (car res)))))

(defun fuzz-session (file out)
  "Write the GUI session of FILE's first frame to OUT, as the editor would."
  (pcase-let ((`(,b ,meas ,pdf) (fuzz--measure file)))
    (with-current-buffer (find-file-noselect file)
      (let ((session (beamer-gui--session-create
                      :buffer (current-buffer) :beg (copy-marker (car b))
                      :end (copy-marker (cdr b) t) :measurements meas)))
        (let ((json (beamer-gui--session-json session pdf)))
          (with-temp-file out (insert json)))))))

(defun fuzz-apply (file message-file)
  "Apply the GUI save MESSAGE-FILE to FILE's first frame, measured afresh."
  (pcase-let ((`(,b ,meas ,_) (fuzz--measure file)))
    (with-current-buffer (find-file-noselect file)
      (let ((message (with-temp-buffer
                       (insert-file-contents message-file)
                       (json-parse-string (buffer-string) :object-type 'plist
                                          :array-type 'list :null-object nil))))
        (beamer-gui-apply-items (car b) (cdr b) (plist-get message :items) meas
                                (plist-get message :background))
        (save-buffer)))))

(defun fuzz-clicks (file clicks-file out)
  "Jump to each click of CLICKS-FILE in FILE; write what point lands on to OUT."
  (with-current-buffer (find-file-noselect file)
    (goto-char (point-min))
    (re-search-forward beamer-gui--frame-begin-regexp)
    (let* ((b (beamer-gui-frame-bounds))
           (clicks (with-temp-buffer
                     (insert-file-contents clicks-file)
                     (json-parse-string (buffer-string) :object-type 'plist
                                        :array-type 'list :null-object nil)))
           (results
            (mapcar (lambda (click)
                      (let ((pos (beamer-gui-goto-click (car b) (cdr b) click)))
                        (buffer-substring-no-properties
                         pos (min (point-max) (+ pos (length (plist-get click :word)))))))
                    clicks)))
      (with-temp-file out (insert (json-serialize (vconcat results)))))))
