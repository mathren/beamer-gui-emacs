;;; beamer-gui-test.el --- Tests for beamer-gui  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Mathieu Renzo

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Run with `make test-el'.  Tests needing pdflatex or Python are
;; skipped when those are missing.

;;; Code:

(require 'ert)
(require 'org)
(require 'beamer-gui)

(defconst bgt-dir (file-name-directory (or load-file-name buffer-file-name))
  "Directory of this file.")


;;;; Fixtures and helpers

(defconst bgt-frame
  "\\documentclass{beamer}
\\usepackage{graphicx}
\\begin{document}
\\begin{frame}{First slide}
  Hello
\\begin{textblock*}{0.45\\paperwidth}(0.05\\paperwidth,0.15\\paperheight) % gui:img1
  \\includegraphics[width=\\linewidth]{fig_slides/a.png}
\\end{textblock*}
\\begin{textblock*}{0.2\\paperwidth}(0.5\\paperwidth,0.4\\paperheight) % gui:arrow1
  \\tikz[x=\\paperwidth,y=\\paperheight]{\\useasboundingbox (0,0) rectangle (0.2,-0.1); \\draw[gui arrow,overlay] (0.2,-0) -- (0,-0.1);}
\\end{textblock*}
\\begin{textblock*}{0.3\\paperwidth}(0.1\\paperwidth,0.6\\paperheight) % gui:t1
  Some $E=mc^2$ text
\\end{textblock*}
\\end{frame}
\\begin{frame}[t]
  \\frametitle{Second: $x^2$}
\\end{frame}
\\begin{frame}[label=fr:first-slide]
\\end{frame}
\\begin{frame}
\\end{frame}
\\end{document}
"
  "Document with three managed blocks in its first frame.")

(defconst bgt-org
  "#+LATEX_CLASS: beamer
#+OPTIONS: toc:nil H:1
#+LATEX_HEADER: \\usepackage[absolute,overlay]{textpos}
* Frame A
text A
* Frame B
\\begin{textblock*}{0.3\\paperwidth}(0.1\\paperwidth,0.2\\paperheight) % gui:img1
  \\includegraphics[width=\\linewidth]{fig_slides/b.png}
\\end{textblock*}
more B
* Frame C
"
  "Org beamer document with a managed block in its second frame.")

(defconst bgt-body
  "\\documentclass{beamer}
\\begin{document}
\\graphicspath{{./fig_slides/}{../figs/}}
\\tikzset{foo/.style={
    red}}
\\section{S}
\\begin{frame}{One}
\\end{frame}
\\begin{frame}{Two}
\\graphicspath{{./ignored/}}
\\end{frame}
\\end{document}
"
  "Document with setup commands between \\begin{document} and frames.")

(defmacro bgt-with (text &rest body)
  "Run BODY in a temporary buffer holding TEXT, point at the start."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,text)
     (goto-char (point-min))
     ,@body))

(defmacro bgt-with-org (text &rest body)
  "Like `bgt-with' with TEXT and BODY, in Org mode."
  (declare (indent 1))
  `(bgt-with ,text (org-mode) ,@body))

(defun bgt-frame-at (string)
  "Move after STRING and return the bounds of its frame."
  (search-forward string)
  (beamer-gui-frame-bounds))

(defun bgt-blocks (&optional bounds)
  "Return element data of the blocks in BOUNDS, default the whole buffer."
  (mapcar #'beamer-gui--item-data
          (beamer-gui-parse-blocks (if bounds (car bounds) (point-min))
                                   (if bounds (cdr bounds) (point-max)))))

(defun bgt-ids (items)
  "Return the identifiers of ITEMS."
  (mapcar (lambda (i) (plist-get i :id)) items))

(defun bgt-near (actual expected &optional tolerance)
  "Return non-nil if every key of plist EXPECTED is near in ACTUAL.
TOLERANCE defaults to 1e-4."
  (cl-loop for (key value) on expected by #'cddr
           always (< (abs (- (plist-get actual key) value)) (or tolerance 1e-4))))

(defun bgt-roundtrip (item)
  "Return ITEM after serialization and parsing."
  (bgt-with (beamer-gui-item-to-tex item)
    (car (bgt-blocks))))

(defun bgt-document (preamble body)
  "Return a beamer document with PREAMBLE and BODY in one frame."
  (concat "\\documentclass{beamer}\n" preamble
          "\\begin{document}\n\\begin{frame}{X}\n" body "\n\\end{frame}\n\\end{document}\n"))

(defun bgt-compile (doc)
  "Compile DOC synchronously and return the PDF file name.
Skip the test if pdflatex is missing; fail if compilation fails."
  (unless (executable-find "pdflatex")
    (ert-skip "pdflatex missing"))
  (let ((result nil))
    (beamer-gui--compile doc (make-temp-file "bgt" t) (make-temp-file "bgt-out" t)
                         (lambda (pdf) (setq result pdf))
                         (lambda (log) (setq result (list 'failed log))))
    (with-timeout (60 (ert-fail "LaTeX timeout"))
      (while (not result) (accept-process-output nil 0.2)))
    (should (stringp result))
    (should (file-exists-p result))
    result))

(defun bgt-pdf-size (pdf)
  "Return (WIDTH HEIGHT) of the first page of PDF via PyMuPDF, or nil."
  (with-temp-buffer
    (when (eq 0 (ignore-errors
                  (call-process "python3" nil t nil "-W" "ignore" "-c"
                                "import pymupdf,sys;r=pymupdf.open(sys.argv[1])[0].rect;print(r.width,r.height)"
                                pdf)))
      (mapcar #'string-to-number (split-string (buffer-string))))))


;;;; Utilities

(ert-deftest bgt-fmt ()
  (should (equal (beamer-gui--fmt 0.5) "0.5"))
  (should (equal (beamer-gui--fmt 1.0) "1"))
  (should (equal (beamer-gui--fmt 100.0) "100"))
  (should (equal (beamer-gui--fmt 0.123456) "0.1235"))
  (should (equal (beamer-gui--fmt -0.00001) "0"))
  (should (equal (beamer-gui--fmt 0) "0")))


;;;; Parsing and serialization

(ert-deftest bgt-parse ()
  (bgt-with bgt-frame
    (let ((items (bgt-blocks)))
      (should (equal (bgt-ids items) '("img1" "arrow1" "t1")))
      (should (equal (nth 0 items)
                     '(:id "img1" :kind "image" :x 0.05 :y 0.15 :w 0.45
                           :file "fig_slides/a.png")))
      (should (equal (plist-get (nth 1 items) :kind) "arrow"))
      (should (bgt-near (nth 1 items) '(:x1 0.7 :y1 0.4 :x2 0.5 :y2 0.5)))
      (should (equal (plist-get (nth 2 items) :kind) "raw")))))

(ert-deftest bgt-ignore-untagged-textblock ()
  (bgt-with "\\begin{textblock*}{0.2\\paperwidth}(0.1\\paperwidth,0.1\\paperheight)\nx\n\\end{textblock*}\n"
    (should-not (bgt-blocks))))

(ert-deftest bgt-roundtrip-image ()
  (let ((item '(:id "img2" :kind "image" :x 0.1 :y 0.2 :w 0.3 :file "fig_slides/x-1.png")))
    (should (equal (bgt-roundtrip item) item))))

(ert-deftest bgt-roundtrip-arrow-all-directions ()
  (dolist (ends '((0.1 0.2 0.5 0.6) (0.5 0.6 0.1 0.2) (0.1 0.6 0.5 0.2) (0.3 0.3 0.3 0.7)))
    (let ((geometry (cl-mapcan #'list '(:x1 :y1 :x2 :y2) ends)))
      (should (bgt-near (bgt-roundtrip (append '(:id "a1" :kind "arrow") geometry))
                        geometry)))))

(ert-deftest bgt-roundtrip-ellipse ()
  (let ((result (bgt-roundtrip '(:id "e1" :kind "ellipse" :x 0.2 :y 0.3 :w 0.1 :h 0.25))))
    (should (equal (plist-get result :kind) "ellipse"))
    (should (bgt-near result '(:x 0.2 :y 0.3 :w 0.1 :h 0.25)))))

(ert-deftest bgt-roundtrip-raw ()
  (let ((result (bgt-roundtrip '(:id "t" :kind "raw" :x 0 :y 0 :w 0.5 :body "  $a$\n  b\n"))))
    (should (equal (string-trim (plist-get result :body)) "$a$\n  b"))))

(ert-deftest bgt-invalid-item ()
  (should-error (beamer-gui-item-to-tex '(:id "bad id" :kind "raw" :x 0 :y 0 :w 1 :body "x")))
  (should-error (beamer-gui-item-to-tex '(:id "ok" :kind "nope"))))


;;;; Frames

(ert-deftest bgt-frame-bounds ()
  (bgt-with bgt-frame
    (let* ((bounds (bgt-frame-at "Hello"))
           (text (buffer-substring (car bounds) (cdr bounds))))
      (should (string-prefix-p "\\begin{frame}{First" text))
      (should (string-suffix-p "\\end{frame}" text)))
    (goto-char (point-min))
    (should-not (beamer-gui-frame-bounds))))

(ert-deftest bgt-frame-bounds-on-begin-line ()
  (bgt-with bgt-frame
    (should (= (car (bgt-frame-at "\\begin{frame}[t")) (line-beginning-position)))))

(ert-deftest bgt-frame-ordinal ()
  (bgt-with bgt-frame
    (should (= (beamer-gui-frame-ordinal (car (bgt-frame-at "frametitle"))) 2))))


;;;; Applying edits

(ert-deftest bgt-apply-move-delete-add ()
  (bgt-with bgt-frame
    (let* ((bounds (bgt-frame-at "Hello"))
           (items (bgt-blocks bounds)))
      (beamer-gui-apply-items
       (car bounds) (cdr bounds)
       (list (plist-put (copy-sequence (nth 0 items)) :x 0.5)  ; moved
             (nth 2 items)                                     ; kept, arrow deleted
             '(:id "ellipse1" :kind "ellipse" :x 0.1 :y 0.1 :w 0.2 :h 0.2)))
      (let* ((bounds (beamer-gui-frame-bounds (car bounds)))
             (after (bgt-blocks bounds)))
        (should (equal (bgt-ids after) '("img1" "t1" "ellipse1")))
        (should (= (plist-get (nth 0 after) :x) 0.5))
        (should (string-match-p "Hello" (buffer-string)))
        (should (string-match-p "gui:ellipse1\\(?:.\\|\n\\)*?\\\\end{textblock\\*}\n\\\\end{frame}"
                                (buffer-substring (car bounds) (cdr bounds))))
        (should (string-match-p "\\\\frametitle{Second" (buffer-string)))))))

(ert-deftest bgt-apply-new-items-keep-order ()
  "New blocks are appended in the given (stacking) order."
  (bgt-with bgt-frame
    (let ((bounds (bgt-frame-at "Hello")))
      (beamer-gui-apply-items
       (car bounds) (cdr bounds)
       '((:id "z2" :kind "ellipse" :x 0 :y 0 :w 0.1 :h 0.1)
         (:id "z1" :kind "arrow" :x1 0 :y1 0 :x2 0.1 :y2 0.1)))
      (should (equal (bgt-ids (bgt-blocks (beamer-gui-frame-bounds (car bounds))))
                     '("z2" "z1"))))))

(ert-deftest bgt-apply-single-undo ()
  (bgt-with bgt-frame
    (buffer-enable-undo)
    (undo-boundary)
    (let ((original (buffer-string))
          (bounds (bgt-frame-at "Hello")))
      (beamer-gui-apply-items (car bounds) (cdr bounds) nil)
      (should-not (equal original (buffer-string)))
      (undo-boundary)
      (primitive-undo 1 (cdr buffer-undo-list))
      (should (equal original (buffer-string))))))

(ert-deftest bgt-apply-idempotent ()
  (bgt-with bgt-frame
    (let* ((bounds (bgt-frame-at "Hello"))
           (items (bgt-blocks bounds)))
      (beamer-gui-apply-items (car bounds) (cdr bounds) items)
      (let ((once (buffer-string))
            (bounds (beamer-gui-frame-bounds (car bounds))))
        (beamer-gui-apply-items (car bounds) (cdr bounds) items)
        (should (equal once (buffer-string)))))))


;;;; Single-frame documents

(ert-deftest bgt-strip-managed-keeps-raw ()
  (let ((text (beamer-gui-strip-managed bgt-frame)))
    (should-not (string-match-p "gui:img1" text))
    (should-not (string-match-p "gui:arrow1" text))
    (should (string-match-p "gui:t1" text))))

(ert-deftest bgt-frame-document ()
  (bgt-with bgt-frame
    (let ((doc (beamer-gui-frame-document (car (bgt-frame-at "frametitle")))))
      (should (string-prefix-p "\\documentclass{beamer}" doc))
      (should (string-match-p "Second" doc))
      (should-not (string-match-p "Hello" doc))
      (should (string-suffix-p "\\end{document}\n" doc)))))

(ert-deftest bgt-image-dir ()
  (with-temp-buffer
    (setq buffer-file-name "/tmp/lec/slides.tex")
    (unwind-protect
        (should (equal (beamer-gui-image-dir) "/tmp/lec/fig_slides"))
      (setq buffer-file-name nil))))

(ert-deftest bgt-strip-notes ()
  (let ((out (beamer-gui-strip-notes
              (concat "\\setbeameroption{show notes}\n"
                      "  \\setbeameroption{show notes on second screen=right}\n"
                      "\\setbeameroption{show only notes}\n"
                      "% \\setbeameroption{show notes on second screen=left}\n"
                      "\\setbeameroption{hide notes}\n"
                      "\\note{show notes here}\n"))))
    (should-not (string-match-p "^[ \t]*\\\\setbeameroption{show" out))
    (should (= 3 (cl-count-if (lambda (line) (string-prefix-p "% [beamer-gui]" line))
                              (split-string out "\n"))))
    (should (string-match-p "^% \\\\setbeameroption{show notes on second screen=left}" out))
    (should (string-match-p "^\\\\setbeameroption{hide notes}" out))
    (should (string-match-p "^\\\\note{show notes here}" out))))

(ert-deftest bgt-frame-document-strips-notes ()
  (bgt-with (string-replace
             "\\begin{document}"
             "\\setbeameroption{show notes on second screen=right}\n\\begin{document}"
             bgt-frame)
    (should-not (string-match-p "^\\\\setbeameroption"
                                (beamer-gui-frame-document (car (bgt-frame-at "Hello")))))))

(ert-deftest bgt-body-setup-carried ()
  (bgt-with bgt-body
    (let ((doc (beamer-gui-frame-document (car (bgt-frame-at "{Two}")))))
      (should (string-match-p "\\\\graphicspath{{./fig_slides/}{../figs/}}" doc))
      (should (string-match-p "\\\\tikzset{foo/.style={\n    red}}" doc))
      (should-not (string-match-p "\\\\section" doc))
      (should-not (string-match-p "{One}" doc)))))

(ert-deftest bgt-graphics-path ()
  (bgt-with bgt-body
    (should (equal (beamer-gui-graphics-path)
                   '("./fig_slides/" "../figs/" "./ignored/")))))


;;;; Labels and preamble

(ert-deftest bgt-label-frames ()
  (bgt-with bgt-frame
    (should (= (beamer-gui-label-frames) 3))
    (let ((text (buffer-string)))
      ;; The title slug collides with the existing fr:first-slide.
      (should (string-match-p "\\\\begin{frame}\\[label=fr:first-slide-2\\]{First slide}" text))
      (should (string-match-p "\\\\begin{frame}\\[t,label=fr:second-x-2\\]" text))
      (should (string-match-p "\\\\begin{frame}\\[label=fr:first-slide\\]\n" text))
      (should (string-match-p "\\\\begin{frame}\\[label=fr:4\\]" text)))
    (should (= (beamer-gui-label-frames) 0))))

(ert-deftest bgt-insert-preamble ()
  (bgt-with "\\documentclass{beamer}\n\\begin{document}\n\\end{document}\n"
    (beamer-gui-insert-preamble)
    (should (string-match-p "{textpos}\\(?:.\\|\n\\)*\\\\begin{document}" (buffer-string)))
    (let ((once (buffer-string)))
      (beamer-gui-insert-preamble)
      (should (equal once (buffer-string))))))


;;;; Minor mode

(ert-deftest bgt-mode-key ()
  "The key works only with `beamer-gui-mode' enabled."
  (with-temp-buffer
    (should-not (eq (key-binding (kbd "C-c g")) #'beamer-gui-edit-frame))
    (beamer-gui-mode 1)
    (should (eq (key-binding (kbd "C-c g")) #'beamer-gui-edit-frame))
    (beamer-gui-mode -1)
    (should-not (eq (key-binding (kbd "C-c g")) #'beamer-gui-edit-frame))))


;;;; Org

(ert-deftest bgt-org-bounds-parse-apply ()
  (bgt-with-org bgt-org
    (let* ((bounds (bgt-frame-at "more B"))
           (items (bgt-blocks bounds)))
      (should (equal (bgt-ids items) '("img1")))
      (beamer-gui-apply-items
       (car bounds) (cdr bounds)
       (list (plist-put (car items) :y 0.5)
             '(:id "arrow1" :kind "arrow" :x1 0.1 :y1 0.1 :x2 0.2 :y2 0.2)))
      (let ((text (buffer-string)))
        (should (string-match-p "(0.1\\\\paperwidth,0.5\\\\paperheight) % gui:img1" text))
        (should (string-match-p "gui:arrow1\\(?:.\\|\n\\)*\\* Frame C" text))
        (should (string-match-p "\\\\end{textblock\\*}\n\\* Frame C" text))))))

(ert-deftest bgt-org-frame-document ()
  (bgt-with-org bgt-org
    (let ((doc (beamer-gui-frame-document (car (bgt-frame-at "more B")))))
      (should (string-match-p "\\\\documentclass" doc))
      (should (string-match-p "gui:img1" doc))
      (should-not (string-match-p "text A" doc)))))


;;;; Compilation (pdflatex)

(ert-deftest bgt-compile-frame ()
  "The background of a frame compiles; its missing image is stripped."
  (bgt-with (string-replace "\\begin{document}"
                            (concat beamer-gui-preamble "\\begin{document}")
                            bgt-frame)
    (bgt-compile (beamer-gui-strip-managed
                  (beamer-gui-frame-document (car (bgt-frame-at "Hello")))))))

(ert-deftest bgt-compile-all-kinds ()
  "Every serialized kind compiles."
  (bgt-compile
   (bgt-document beamer-gui-preamble
                 (mapconcat #'beamer-gui-item-to-tex
                            '((:id "a" :kind "arrow" :x1 0.6 :y1 0.2 :x2 0.2 :y2 0.7)
                              (:id "e" :kind "ellipse" :x 0.4 :y 0.4 :w 0.2 :h 0.1)
                              (:id "r" :kind "raw" :x 0.1 :y 0.1 :w 0.3 :body "$x^2$"))
                            "\n"))))

(ert-deftest bgt-preamble-with-existing-textpos ()
  "The preamble works when textpos and TikZ are already loaded."
  (bgt-compile
   (bgt-document
    (concat "\\usepackage[absolute,overlay]{textpos}\n\\usepackage{tikz}\n"
            "\\setlength{\\TPHorizModule}{\\paperwidth}\\setlength{\\TPVertModule}{\\paperheight}\n"
            beamer-gui-preamble)
    (concat "\\begin{textblock}{0.2}[0,0](0.75,0.25)x\\end{textblock}\n"
            (beamer-gui-item-to-tex
             '(:id "a" :kind "arrow" :x1 0.1 :y1 0.1 :x2 0.3 :y2 0.3))))))

(ert-deftest bgt-compile-second-screen-is-slide-size ()
  "With second-screen notes the frame still compiles slide-sized."
  (bgt-with (bgt-document (concat "\\usepackage{pgfpages}\n"
                                  "\\setbeameroption{show notes on second screen=right}\n"
                                  beamer-gui-preamble)
                          "x\\note{n}")
    (let ((size (bgt-pdf-size
                 (bgt-compile (beamer-gui-frame-document (car (bgt-frame-at "{X}")))))))
      (skip-unless size)
      ;; Default beamer page is 128mm x 96mm: 4:3, not 8:3.
      (should (< (abs (- (/ (car size) (cadr size)) (/ 4.0 3))) 0.01)))))

(ert-deftest bgt-end-to-end-fake-gui ()
  "Edit, compile, GUI save, buffer update, background sent back."
  (skip-unless (executable-find "pdflatex"))
  (let* ((dir (file-name-as-directory (make-temp-file "bgt-e2e" t)))
         (file (expand-file-name "s.tex" dir))
         (done (expand-file-name "done.txt" dir))
         (beamer-gui-script (expand-file-name "fake_gui.py" bgt-dir)))
    (with-temp-file file
      (insert (string-replace "\\begin{document}"
                              (concat beamer-gui-preamble "\\begin{document}")
                              bgt-frame)))
    (with-current-buffer (find-file-noselect file)
      (unwind-protect
          (progn
            (bgt-frame-at "Hello")
            (beamer-gui-edit-frame)
            (with-timeout (60 (ert-fail "Timeout"))
              (while (not (file-exists-p done)) (accept-process-output nil 0.2)))
            (let ((text (buffer-string)))
              (should (string-match-p "(0.5\\\\paperwidth,0.15\\\\paperheight) % gui:img1" text))
              (should (string-match-p "gui:arrow1" text))
              (should (string-match-p "gui:arrow9" text)))
            (should (string-match-p "background" (with-temp-buffer
                                                    (insert-file-contents done)
                                                    (buffer-string)))))
        (set-buffer-modified-p nil)
        (kill-buffer)))))

(provide 'beamer-gui-test)
;;; beamer-gui-test.el ends here
