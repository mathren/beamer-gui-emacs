;;; beamer-gui-test.el --- Tests for beamer-gui  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Mathieu Renzo

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Run with `make test-el'.  Tests needing pdflatex are skipped when
;; it is missing.  test/test_layout.py checks that moving an element
;; leaves the rest of the slide in place.

;;; Code:

(require 'ert)
(require 'org)
(require 'beamer-gui)

(defconst bgt-dir (file-name-directory (or load-file-name buffer-file-name))
  "Directory of this file.")


;;;; Fixtures and helpers

(defconst bgt-frame
  "\\documentclass{beamer}
\\usepackage{tcolorbox}
\\begin{document}
\\begin{frame}[fragile]{First slide}
  Hello
  \\begin{center}
    \\includegraphics<2->[width=0.3\\textwidth]{fig_slides/a.png}
  \\end{center}
  \\begin{block}{B}
    In a block % with a comment \\begin{tcolorbox}
  \\end{block}
  \\begin{textblock}{0.2}[0,0](0.75,0.25)
    tb
  \\end{textblock}
  \\begin{verbatim}
\\includegraphics{not-this}
  \\end{verbatim}
%%% beamer-gui img1
\\begin{textblock*}{0.45\\paperwidth}(0.05\\paperwidth,0.15\\paperheight)
  \\includegraphics[width=\\linewidth]{fig_slides/b.png}
\\end{textblock*}
%%% ---
\\begin{textblock*}{0.2\\paperwidth}(0.5\\paperwidth,0.4\\paperheight) % gui:arrow1
  \\tikz[x=\\paperwidth,y=\\paperheight]{\\useasboundingbox (0,0) rectangle (0.2,-0.1); \\draw[gui arrow,overlay] (0.2,-0) -- (0,-0.1);}
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
  "Document whose first frame has flow elements, a textblock, a new
and a version 0.1 block.")

(defmacro bgt-with (text &rest body)
  "Run BODY in a temporary buffer holding TEXT, point at the start."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,text)
     (goto-char (point-min))
     ,@body))

(defun bgt-frame-at (string)
  "Move after STRING and return the bounds of its frame."
  (search-forward string)
  (beamer-gui-frame-bounds))

(defun bgt-model (&optional string)
  "Return the model of the frame containing STRING (default Hello)."
  (let ((b (bgt-frame-at (or string "Hello"))))
    (beamer-gui-frame-model (car b) (cdr b))))

(defun bgt-ids (items)
  "Return the identifiers of ITEMS."
  (mapcar (lambda (i) (plist-get i :id)) items))

(defun bgt-near (actual expected)
  "Return non-nil if every number of plist EXPECTED is within 1e-4 in ACTUAL."
  (cl-loop for (key value) on expected by #'cddr
           always (< (abs (- (plist-get actual key) value)) 1e-4)))

(defun bgt-roundtrip (item)
  "Return ITEM after serialization and parsing."
  (bgt-with (beamer-gui-item-to-tex item)
    (beamer-gui--item-data (car (beamer-gui-parse-blocks (point-min) (point-max))))))

(defun bgt-compile (doc)
  "Compile DOC synchronously; return (PDF . OUTPUT-DIRECTORY).
Skip the test if pdflatex is missing; fail if compilation fails."
  (unless (executable-find "pdflatex") (ert-skip "pdflatex missing"))
  (let ((out (make-temp-file "bgt-out" t)) result)
    (beamer-gui--compile doc bgt-dir out
                         (lambda (pdf) (setq result pdf))
                         (lambda (log) (setq result (list 'failed log))))
    (with-timeout (90 (ert-fail "LaTeX timeout"))
      (while (not result) (accept-process-output nil 0.2)))
    (should (stringp result))
    (cons result out)))


;;;; Blocks written by beamer-gui

(ert-deftest bgt-fmt ()
  (should (equal (beamer-gui--fmt 0.5) "0.5"))
  (should (equal (beamer-gui--fmt 100.0) "100"))
  (should (equal (beamer-gui--fmt 0.123456) "0.1235"))
  (should (equal (beamer-gui--fmt -0.00001) "0"))
  (should (equal (beamer-gui--fmt 2.345 2) "2.35")))

(ert-deftest bgt-parse-new-and-legacy ()
  (bgt-with bgt-frame
    (let ((blocks (plist-get (bgt-model) :blocks)))
      (should (equal (bgt-ids blocks) '("img1" "arrow1")))
      (should (equal (beamer-gui--item-data (nth 0 blocks))
                     '(:id "img1" :kind "image" :x 0.05 :y 0.15 :w 0.45
                           :file "fig_slides/b.png")))
      (should (plist-get (nth 1 blocks) :legacy))
      (should (bgt-near (nth 1 blocks) '(:x1 0.7 :y1 0.4 :x2 0.5 :y2 0.5)))
      (should (equal (plist-get (nth 1 blocks) :opts) "")))))

(ert-deftest bgt-roundtrip-drawn-kinds ()
  (dolist (item '((:id "i" :kind "image" :x 0.1 :y 0.2 :w 0.3 :file "f.png")
                  (:id "e" :kind "ellipse" :x 0.2 :y 0.3 :w 0.1 :h 0.25
                       :opts "draw=Maroon, dashed")
                  (:id "r" :kind "rect" :x 0.2 :y 0.3 :w 0.1 :h 0.25
                       :opts "draw=bblue, fill=Yellow, fill opacity=0.5")
                  (:id "t" :kind "text" :x 0.1 :y 0.1 :w 0.3 :opts "text=red"
                       :text "A {nested} $x$")
                  (:id "raw" :kind "raw" :x 0 :y 0 :w 0.5 :body "$a$")))
    (should (equal (bgt-roundtrip item) item)))
  (dolist (ends '((0.1 0.2 0.5 0.6) (0.5 0.6 0.1 0.2) (0.1 0.6 0.5 0.2)))
    (let* ((geometry (cl-mapcan #'list '(:x1 :y1 :x2 :y2) ends))
           (item (append '(:id "a" :kind "arrow" :opts "-{Stealth[length=2mm]}, bend left=20")
                         geometry))
           (back (bgt-roundtrip item)))
      (should (bgt-near back geometry))
      (should (equal (plist-get back :opts) "-{Stealth[length=2mm]}, bend left=20")))))

(ert-deftest bgt-block-format ()
  (should (equal (beamer-gui-item-to-tex '(:id "e1" :kind "ellipse" :x 0.1 :y 0.2 :w 0.2
                                               :h 0.1 :opts "draw=Maroon"))
                 (concat "%%% beamer-gui e1\n"
                         "\\begin{textblock*}{0.2\\paperwidth}(0.1\\paperwidth,0.2\\paperheight)\n"
                         "  \\tikz[x=\\paperwidth,y=\\paperheight]{\\useasboundingbox (0,0) rectangle (0.2,-0.1); "
                         "\\draw[gui ellipse, draw=Maroon] (0.1,-0.05) ellipse[x radius=0.1,y radius=0.05];}\n"
                         "\\end{textblock*}\n%%% ---")))
  (should-error (beamer-gui-item-to-tex '(:id "bad id" :kind "raw" :x 0 :y 0 :w 1 :body "x")))
  (should-error (beamer-gui-item-to-tex '(:id "ok" :kind "nope"))))


;; Found by fuzzing: a block a hand edit left unreadable must not
;; stop the frame from opening.
(ert-deftest bgt-unreadable-block-is-raw ()
  (bgt-with (concat "\\begin{frame}\n"
                    (beamer-gui-item-to-tex '(:id "t1" :kind "text" :x 0.1 :y 0.1 :w 0.2
                                                  :opts "" :text "{"))
                    "\n\\end{frame}\n")
    (let ((block (car (beamer-gui-parse-blocks (point-min) (point-max)))))
      (should (equal (plist-get block :kind) "raw"))
      (should (equal (plist-get block :body) "\\tikz\\node[gui text] {{};")))))


;;;; Movable elements of the text

(ert-deftest bgt-scan-elements ()
  (bgt-with bgt-frame
    (let ((elements (plist-get (bgt-model) :elements)))
      (should (equal (mapcar (lambda (e) (list (plist-get e :id) (plist-get e :kind)
                                               (plist-get e :name) (plist-get e :inline)))
                             elements)
                     '(("c1" "flow" "includegraphics" t)
                       ("c2" "flow" "block" nil)
                       ("c3" "textblock" "textblock" nil))))
      (should (string-match-p
               "\\`\\\\includegraphics<2->\\[width=0.3\\\\textwidth\\]{fig_slides/a.png}\\'"
               (buffer-substring (plist-get (nth 0 elements) :beg)
                                 (plist-get (nth 0 elements) :end)))))))

;; Found by fuzzing: macro arguments being typed, with unbalanced
;; brackets, must not break the scan.
(ert-deftest bgt-scan-tolerates-unbalanced-arguments ()
  (bgt-with "\\begin{frame}{F}\n\\includegraphics[width= \\begin{block}{B}x\\end{block}\n\\end{frame}\n"
    (should (equal (mapcar (lambda (e) (plist-get e :name))
                           (plist-get (beamer-gui-frame-model (point-min) (point-max)) :elements))
                   '("block"))))
  (bgt-with "\\begin{frame}{F}\n\\begin{block}{B}x\n\\end{frame}\n"
    (should-error (beamer-gui-frame-model (point-min) (point-max)) :type 'user-error)))

(ert-deftest bgt-frame-bounds ()
  (bgt-with bgt-frame
    (let ((b (bgt-frame-at "Hello")))
      (should (string-prefix-p "\\begin{frame}[fragile]{First" (buffer-substring (car b) (cdr b))))
      (should (string-suffix-p "\\end{frame}" (buffer-substring (car b) (cdr b)))))
    (goto-char (point-min))
    (should-not (beamer-gui-frame-bounds))
    (should (= (beamer-gui-frame-ordinal (car (bgt-frame-at "Second"))) 2))))


;;;; Editing the user's code

(ert-deftest bgt-lengths ()
  (should (equal (beamer-gui--parse-length "0.3\\textwidth") '(0.3 . "\\textwidth")))
  (should (equal (beamer-gui--parse-length "\\linewidth") '(1.0 . "\\linewidth")))
  (should (equal (beamer-gui--parse-length "2 cm") '(2.0 . "cm")))
  (should (equal (beamer-gui--scale-length "0.3\\textwidth" 2) "0.6\\textwidth"))
  (should (equal (beamer-gui--scale-length "\\linewidth" 0.5) "0.5\\linewidth"))
  (should (equal (beamer-gui--shift-length "1cm" 28.45276 nil) "2cm"))
  (should (equal (beamer-gui--shift-length "0.5\\paperwidth" 100 '(("\\paperwidth" . 400)))
                 "0.75\\paperwidth"))
  (should-not (beamer-gui--shift-length "\\mylength" 10 nil)))

(ert-deftest bgt-resize-code ()
  (should (equal (beamer-gui-resize-code "\\includegraphics[width=0.3\\textwidth,page=2]{a}"
                                         "includegraphics" 2 0.5)
                 "\\includegraphics[width=0.6\\textwidth, page=2]{a}"))
  (should (equal (beamer-gui-resize-code "\\includegraphics<2>[scale=0.5]{a}"
                                         "includegraphics" 3 0.5)
                 "\\includegraphics<2>[scale=1.5]{a}"))
  (should (equal (beamer-gui-resize-code "\\includegraphics{a}" "includegraphics" 3 0.25)
                 "\\includegraphics[width=0.25\\paperwidth]{a}"))
  (should (equal (beamer-gui-resize-code "\\begin{tcolorbox}[colback=red]x\\end{tcolorbox}"
                                         "tcolorbox" 0.5 0.4)
                 "\\begin{tcolorbox}[width=0.5\\linewidth, colback=red]x\\end{tcolorbox}"))
  (should (equal (beamer-gui-resize-code "\\begin{minipage}[t]{0.4\\textwidth}x\\end{minipage}"
                                         "minipage" 0.5 0.2)
                 "\\begin{minipage}[t]{0.2\\textwidth}x\\end{minipage}"))
  (should-not (beamer-gui-resize-code "\\begin{block}{B}x\\end{block}" "block" 2 0.5)))

(ert-deftest bgt-textblock-head ()
  (let ((units '(("\\paperwidth" . 400) ("\\paperheight" . 300)
                 ("\\TPHorizModule" . 40) ("\\TPVertModule" . 30))))
    (should (equal (beamer-gui-edit-textblock-head
                    "\\begin{textblock}{2}[0.5,0](8,13)" 40 -30 1.5 units)
                   "\\begin{textblock}{3}[0.5,0](9,12)"))
    (should (equal (beamer-gui-edit-textblock-head
                    "\\begin{textblock*}{3cm}(1cm,0.8\\paperheight)" 28.45276 30 1 units)
                   "\\begin{textblock*}{3cm}(2cm,0.9\\paperheight)"))
    (should-not (beamer-gui-edit-textblock-head
                 "\\begin{textblock*}{3cm}(\\myx,1cm)" 10 0 1 units))))


;;;; Single-frame documents and measurements

(ert-deftest bgt-measure-document ()
  (bgt-with bgt-frame
    (pcase-let ((`(,pre ,setup ,frame) (beamer-gui--frame-parts (car (bgt-frame-at "Hello")))))
      (let ((doc (beamer-gui-measure-document pre setup frame '("red" "Maroon"))))
        (dolist (needle '("\\begin{bgmeasure}{c1}\\includegraphics<2->"
                          "\\bgmarkv{c2}{b}\\begin{block}" "\\end{block}\\bgmarkv{c2}{e}"
                          "\\bgmarkv{@A}{end}" "\\addtocounter{framenumber}{-1}"
                          "\\begin{invisibleenv}\\begin{block}" "\\bgmarkv{@B}{end}"
                          "\\bgswatch{Maroon}"))
          (should (string-match-p (regexp-quote needle) doc)))
        ;; The background frame has neither drawn blocks nor textblocks.
        (let ((background (substring doc (string-match "addtocounter" doc))))
          (should-not (string-match-p "gui:arrow1\\|beamer-gui img1\\|{textblock}" background)))))))

(ert-deftest bgt-strip-notes ()
  (let ((out (beamer-gui-strip-notes
              "\\setbeameroption{show notes on second screen=right}\n% \\setbeameroption{show notes}\n")))
    (should (string-prefix-p "% [beamer-gui] \\setbeameroption" out))
    (should (string-match-p "^% \\\\setbeameroption{show notes}" out))))

(ert-deftest bgt-document-colors ()
  (let* ((dir (make-temp-file "bgt" t))
         (setup (expand-file-name "setup.tex" dir)))
    (with-temp-file setup
      (insert "\\definecolor{bblue}{HTML}{144b7a}\n\\colorlet{soft}{bblue!20}\n"
              "% \\definecolor{commented}{rgb}{0,0,0}\n\\definecolors{one,two}\n"))
    (let ((colors (beamer-gui-document-colors
                   "\\documentclass[xcolor=dvipsnames]{beamer}\n\\input{./setup}\n" dir)))
      (should (equal (seq-take colors 4) '("bblue" "soft" "one" "two")))
      (should-not (member "commented" colors))
      (should (member "Maroon" colors))
      (should (equal (car (last colors)) "violet")))))

(ert-deftest bgt-measurements ()
  (let ((file (make-temp-file "bgt" nil ".bgpos")))
    (with-temp-file file
      (insert "@paper p pw=400.0pt ph=300.0pt\n"
              "c2 b page=1 x=655360 y=13107200 lw=380.0pt tw=380.0pt pd=2.0pt ls=4.0pt\n"
              "c2 e page=1 x=655360 y=6553600 lw=380.0pt tw=380.0pt pd=3.0pt ls=5.0pt\n"
              "c1 i page=1 x=1310720 y=16384000 lw=380.0pt tw=380.0pt wd=40.0pt ht=30.0pt dp=0.0pt\n"
              "@A end page=1 x=0 y=0 lw=380.0pt tw=380.0pt\n"
              "@B end page=2 x=0 y=0 lw=380.0pt tw=380.0pt\n"
              "color:red s page=3 x=0 y=6553600 lw=1pt tw=1pt\n"))
    (let* ((m (beamer-gui-measurements file))
           (block (beamer-gui--measured "c2" m))
           (image (beamer-gui--measured "c1" m)))
      (should (equal (list (plist-get m :page-a) (plist-get m :page-b) (plist-get m :page-s))
                     '(0 1 2)))
      ;; Block: from 200pt - 4pt (skip before) down to 100pt, plus depth 3pt.
      (should (equal (plist-get block :box) (list 0.025 (/ 104.0 300) 0.95 (/ 99.0 300))))
      (should (equal (list (plist-get block :height) (plist-get block :skip)
                           (plist-get block :before-skip))
                     '(96.0 5.0 4.0)))
      (should (equal (plist-get image :box) (list 0.05 (/ 20.0 300) 0.1 (/ 30.0 300)))))))


;;;; Applying the GUI's changes

(defun bgt-apply (items &optional measurements background)
  "Apply ITEMS and BACKGROUND to the first frame of the current buffer."
  (goto-char (point-min))
  (let ((b (bgt-frame-at "Hello")))
    (beamer-gui-apply-items (car b) (cdr b) items measurements background)))

(defun bgt-gui-items ()
  "Return the drawn blocks of the first frame as the GUI sends them."
  (goto-char (point-min))
  (mapcar #'beamer-gui--item-data (plist-get (bgt-model) :blocks)))

(ert-deftest bgt-apply-unchanged-is-identity ()
  (bgt-with bgt-frame
    (let ((items (bgt-gui-items)))
      (goto-char (point-min))
      (bgt-apply items)
      (should (equal (buffer-string) bgt-frame)))))

(ert-deftest bgt-apply-add-change-delete ()
  (bgt-with bgt-frame
    (let ((items (bgt-gui-items)))
      (goto-char (point-min))
      (bgt-apply (list (plist-put (copy-sequence (nth 0 items)) :x 0.5)   ; moved
                       ;; arrow1 deleted; a rectangle added
                       '(:id "rect1" :kind "rect" :x 0.1 :y 0.1 :w 0.2 :h 0.1
                             :opts "draw=bblue")))
      (let ((text (buffer-string)))
        (should (string-match-p "(0.5\\\\paperwidth,0.15\\\\paperheight)" text))
        (should-not (string-match-p "gui:arrow1" text))
        (should (string-match-p "%%% beamer-gui rect1\n\\(?:.*\n\\)*%%% ---\n\\\\end{frame}" text))
        (should (string-match-p "\\\\draw\\[gui rect, draw=bblue\\]" text))))))

(ert-deftest bgt-apply-migrates-changed-legacy-block ()
  (bgt-with bgt-frame
    (let ((items (bgt-gui-items)))
      (goto-char (point-min))
      (bgt-apply (list (nth 0 items) (plist-put (copy-sequence (nth 1 items)) :opts "draw=Maroon")))
      (should (string-match-p "%%% beamer-gui arrow1\n" (buffer-string)))
      (should-not (string-match-p "% gui:arrow1" (buffer-string))))))

(ert-deftest bgt-apply-single-undo ()
  (bgt-with bgt-frame
    (buffer-enable-undo)
    (undo-boundary)
    (bgt-apply nil)
    (should-not (equal (buffer-string) bgt-frame))
    (undo-boundary)
    (primitive-undo 1 (cdr buffer-undo-list))
    (should (equal (buffer-string) bgt-frame))))

(defconst bgt-measured
  (let ((boxes (make-hash-table :test #'equal)))
    (puthash "c1" (list :i (list :x 100.0 :y 150.0 :wd 120.0 :ht 90.0 :dp 0.0
                                 :lw 400.0 :tw 400.0))
             boxes)
    (puthash "c2" (list :b (list :x 20.0 :y 140.0 :lw 400.0 :tw 400.0 :pd 2.0 :ls 4.0)
                        :e (list :x 20.0 :y 100.0 :lw 400.0 :tw 400.0 :pd 3.0 :ls 5.0))
             boxes)
    (puthash "c3" (list :b (list :x 300.0 :y 250.0 :lw 80.0 :tw 80.0 :hm 40.0 :vm 30.0)
                        :e (list :x 300.0 :y 230.0 :lw 80.0 :tw 80.0 :pd 2.0))
             boxes)
    (list :paper '(400.0 300.0) :boxes boxes
          :frame (list :lw 380.0 :tw 380.0)))
  "Measurements of the first frame of `bgt-frame', made up.")

(defun bgt-move (id dx dy &optional factor)
  "Return the GUI item ID of `bgt-measured' moved by DX, DY, resized by FACTOR."
  (let* ((box (plist-get (beamer-gui--measured id bgt-measured) :box))
         (new (list (+ (nth 0 box) dx) (+ (nth 1 box) dy)
                    (* (nth 2 box) (or factor 1)) (* (nth 3 box) (or factor 1)))))
    (list :id id :kind (if (equal id "c3") "textblock" "flow") :box new :box0 box)))

(ert-deftest bgt-wrap-inline ()
  (bgt-with bgt-frame
    (bgt-apply (append (bgt-gui-items) (list (bgt-move "c1" 0.1 0 2))) bgt-measured)
    (goto-char (point-min))
    (should (search-forward
             (concat "    %%% beamer-gui w1 (moved includegraphics)\n"
                     "    \\beamerguihspace{120pt}{90pt}{0pt}%\n"
                     "    \\begin{textblock*}{0.6\\paperwidth}(0.35\\paperwidth,0.2\\paperheight)\n"
                     "      \\setlength{\\textwidth}{1\\paperwidth}% as outside the block\n"
                     "      \\includegraphics<2->[width=0.6\\textwidth]{fig_slides/a.png}\n"
                     "    \\end{textblock*}\n"
                     "    %%% ---\n  \\end{center}")
             nil t))))

(ert-deftest bgt-wrap-display-rewrap-unwrap ()
  (bgt-with bgt-frame
    (bgt-apply (append (bgt-gui-items) (list (bgt-move "c2" 0.1 0))) bgt-measured)
    (goto-char (point-min))
    (should (search-forward
             (concat "  %%% beamer-gui w1 (moved block)\n"
                     "  \\begin{textblock*}{1\\paperwidth}(0.15\\paperwidth,0.5333\\paperheight)\n"
                     "    \\beamerguicontext{4pt}{2pt}% as in the text\n"
                     "    \\begin{block}{B}\n")
             nil t))
    (should (search-forward "  \\end{textblock*}\n  \\beamerguivspace{36pt}{3pt}{5pt}\n  %%% ---\n"
                            nil t))
    ;; Move it again: only the textblock* line changes.
    (let* ((boxes (make-hash-table :test #'equal))
           (m (list :paper '(400.0 300.0) :boxes boxes :frame '(:lw 380.0 :tw 380.0))))
      (puthash "w1" (gethash "c2" (plist-get bgt-measured :boxes)) boxes)
      (let ((item (bgt-move "c2" 0 0.1)))
        (setq item (plist-put item :id "w1"))
        (setq item (plist-put item :kind "wrap"))
        (goto-char (point-min))
        (bgt-apply (append (bgt-gui-items) (list item)) m)))
    (should (string-match-p
             "{1\\\\paperwidth}(0.05\\\\paperwidth,0.6333\\\\paperheight)" (buffer-string)))
    ;; Unwrap restores the original code.
    (goto-char (point-min))
    (search-forward "beamerguicontext")
    (beamer-gui-unwrap)
    (should (string-match-p "  \\\\begin{block}{B}\n    In a block" (buffer-string)))
    (should-not (string-match-p "beamer-gui w1\\|beamerguivspace" (buffer-string)))))

(ert-deftest bgt-move-user-textblock ()
  (bgt-with bgt-frame
    (bgt-apply (append (bgt-gui-items) (list (bgt-move "c3" 0.1 0.1))) bgt-measured)
    (goto-char (point-min))
    (should (search-forward
             (concat "  %%% beamer-gui tb1 (textblock)\n"
                     "  \\begin{textblock}{0.2}[0,0](1.75,1.25)\n"
                     "    tb\n  \\end{textblock}\n  %%% ---")
             nil t))))


;;;; Frame background

(ert-deftest bgt-background-text ()
  (should-not (beamer-gui--background-text '(:color "" :image "")))
  (should (equal (beamer-gui--background-text '(:color "bblue!10"))
                 (cons (concat "%%% beamer-gui background\n{%\n"
                               "\\setbeamercolor{background canvas}{bg=bblue!10}%\n%%% ---\n")
                       "\n%%% beamer-gui background-end\n}%\n%%% ---")))
  (should (string-match-p
           "\\\\usebackgroundtemplate{\\\\includegraphics\\[width=\\\\paperwidth,height=\\\\paperheight\\]{bg.png}}"
           (car (beamer-gui--background-text '(:image "bg.png"))))))

(ert-deftest bgt-background-set-replace-remove ()
  (bgt-with bgt-frame
    (let ((items (bgt-gui-items)))
      (bgt-apply items nil '(:color "red" :image ""))
      (goto-char (point-min))
      (should (search-forward "%%% beamer-gui background\n{%\n\\setbeamercolor{background canvas}{bg=red}%\n%%% ---\n\\begin{frame}[fragile]{First slide}" nil t))
      (should (search-forward "\\end{frame}\n%%% beamer-gui background-end\n}%\n%%% ---\n\\begin{frame}[t]" nil t))
      (goto-char (point-min))
      (let ((b (bgt-frame-at "Hello")))
        (should (equal (seq-take (beamer-gui-frame-background (car b) (cdr b)) 4)
                       '(:color "red" :image ""))))
      ;; Replacing keeps a single pair of blocks.
      (bgt-apply items nil '(:color "" :image "fig_slides/bg.png"))
      (should (= 1 (how-many "beamer-gui background$" (point-min) (point-max))))
      (should (= 1 (how-many "beamer-gui background-end" (point-min) (point-max))))
      (should-not (string-match-p "background canvas" (buffer-string)))
      (goto-char (point-min))
      (let ((b (bgt-frame-at "Hello")))
        (should (equal (plist-get (beamer-gui-frame-background (car b) (cdr b)) :image)
                       "fig_slides/bg.png")))
      ;; Removing restores the document.
      (bgt-apply items nil '(:color "" :image ""))
      (should (equal (buffer-string) bgt-frame)))))

(ert-deftest bgt-background-not-an-element ()
  (bgt-with bgt-frame
    (bgt-apply (bgt-gui-items) nil '(:color "red"))
    (goto-char (point-min))
    (should (equal (bgt-ids (plist-get (bgt-model) :blocks)) '("img1" "arrow1")))))

(ert-deftest bgt-background-compiled ()
  "The background page of the measuring document has the frame's background."
  (unless (executable-find "python3") (ert-skip "python3 missing"))
  (bgt-with (string-replace "\\begin{document}"
                            (concat beamer-gui-preamble "\\begin{document}")
                            (replace-regexp-in-string "fig_slides/[ab].png" "example-image"
                                                      bgt-frame))
    (bgt-apply (bgt-gui-items) nil '(:color "red"))
    (goto-char (point-min))
    (pcase-let* ((`(,pre ,setup ,frame) (beamer-gui--frame-parts (car (bgt-frame-at "Hello"))))
                 (`(,pdf . ,out) (bgt-compile (beamer-gui-measure-document pre setup frame nil)))
                 (m (beamer-gui-measurements (expand-file-name "frame.bgpos" out))))
      (with-temp-buffer
        (unless (eq 0 (call-process
                       "python3" nil t nil "-W" "ignore" "-c"
                       "import pymupdf,sys;p=pymupdf.open(sys.argv[1])[int(sys.argv[2])];print(*p.get_pixmap(dpi=20).pixel(2,60))"
                       pdf (number-to-string (plist-get m :page-b))))
          (ert-skip "PyMuPDF missing"))
        (should (equal (split-string (buffer-string)) '("255" "0" "0")))))))


;;;; Jumping from the GUI to the source

(defconst bgt-click-frame
  "\\begin{frame}{Title word}
  First text here. % a comment with Second
  \\begin{itemize}
  \\item Second item
  \\item Second item again
  \\end{itemize}
  The text with Item, item and B b.
\\end{frame}
"
  "Frame for click tests.")

(defun bgt-click (click)
  "Return the text at the position CLICK jumps to in `bgt-click-frame'."
  (bgt-with bgt-click-frame
    (let ((pos (beamer-gui-goto-click (point-min) (point-max) click)))
      (buffer-substring pos (min (point-max) (+ pos 12))))))

(ert-deftest bgt-click-plain-and-title ()
  (should (string-prefix-p "First" (bgt-click '(:word "First"))))
  (should (string-prefix-p "word}" (bgt-click '(:word "word")))))      ; frame title

(ert-deftest bgt-click-skips-comments-macros-and-case ()
  ;; "item" as a word, not \item nor itemize; "b" not "B".
  (should (string-prefix-p "item and" (bgt-click '(:word "item"))))
  (should (string-prefix-p "b." (bgt-click '(:word "b"))))
  ;; After \\ (a line break) a word is text, not a macro name.
  (bgt-with "\\begin{frame}\nTwo\\\\lines\n\\end{frame}\n"
    (goto-char (beamer-gui-goto-click (point-min) (point-max) '(:word "lines")))
    (should (looking-at-p "lines"))))

(ert-deftest bgt-click-element-nth-and-neighbours ()
  (with-temp-buffer
    (insert bgt-click-frame)
    (let* ((id (plist-get (car (plist-get (beamer-gui-frame-model (point-min) (point-max))
                                          :elements))
                          :id))
           (second (lambda (click)
                     (let ((pos (beamer-gui-goto-click (point-min) (point-max)
                                                       (append (list :element id) click))))
                       (buffer-substring pos (line-end-position))))))
      (should (equal (funcall second '(:word "Second" :nth 1)) "Second item again"))
      (should (equal (funcall second '(:word "Second" :nth 0 :after ("item" "again")))
                     "Second item again"))
      ;; A word not in the element's source is looked for in the frame.
      (should (string-prefix-p "First" (funcall second '(:word "First")))))))

(ert-deftest bgt-click-fallbacks ()
  ;; Maths or accents: a neighbour; nothing at all: the frame start.
  (should (string-prefix-p "here." (bgt-click '(:word "x2" :before ("here")))))
  (should (string-prefix-p "\\begin{frame" (bgt-click '(:word ""))))
  ;; Code shown verbatim is looked for as printed.
  (should (string-prefix-p "\\item Second"
                           (bgt-click '(:word "item" :raw "\\item Second")))))


;;;; Styles

(ert-deftest bgt-gui-items-image-files ()
  (bgt-with bgt-frame
    (let* ((b (bgt-frame-at "Hello"))
           (items (beamer-gui-gui-items (beamer-gui-frame-model (car b) (cdr b)) bgt-measured)))
      (should (equal (plist-get (cl-find "c1" items :key (lambda (i) (plist-get i :id))
                                         :test #'equal)
                                :file)
                     "fig_slides/a.png"))
      (should (equal (plist-get (cl-find "c2" items :key (lambda (i) (plist-get i :id))
                                         :test #'equal)
                                :file)
                     "")))))

(ert-deftest bgt-compile-styles ()
  "Every style the GUI offers compiles."
  (bgt-compile
   (concat "\\documentclass{beamer}\n" beamer-gui-preamble
           "\\begin{document}\n\\begin{frame}\n"
           (mapconcat
            #'beamer-gui-item-to-tex
            (append
             (cl-loop for tips in '("->" "<-" "<->" "-" "-latex" "latex-latex" "-stealth"
                                    "stealth-stealth" "|->" "|-|")
                      for i from 1
                      collect (list :id (format "a%d" i) :kind "arrow" :x1 0.1 :y1 (* i 0.05)
                                    :x2 0.4 :y2 (* i 0.05)
                                    :opts (concat "draw=blue, very thick, dashed, " tips
                                                  ", bend left=20, draw opacity=0.5")))
             '((:id "r" :kind "rect" :x 0.5 :y 0.1 :w 0.2 :h 0.1
                    :opts "draw=red, fill=blue, fill opacity=0.3, rounded corners=6pt, dotted")
               (:id "e" :kind "ellipse" :x 0.5 :y 0.4 :w 0.2 :h 0.1
                    :opts "draw=red, ultra thick, draw opacity=0.4")
               (:id "t" :kind "text" :x 0.5 :y 0.6 :w 0.3
                    :opts "text=red, text opacity=0.4" :text "Styled")))
            "\n")
           "\n\\end{frame}\n\\end{document}\n")))


;;;; The document's own pictures and boxes

(defconst bgt-definitions-preamble
  "\\newcommand{\\member}[4][40pt]{%
  \\begin{tabular}[t]{@{}c@{}}\\includegraphics[width=#1]{#2}\\\\#3\\\\#4\\end{tabular}}
\\newcommand\\tikzmark[1]{\\tikz[remember picture,overlay]\\node (#1) {};}
\\newcommand{\\hcancel}[1]{\\tikz[baseline=(t.base)]{\\node (t) {#1};}}
\\newcommand{\\logo}{\\includegraphics{logo}}
\\newenvironment<>{varblock}[2][.9\\textwidth]{\\begin{actionenv}#3}{\\end{actionenv}}
\\newenvironment{plain}[1]{}{}
"
  "Definitions in the style of beamer_template_mrenzo's setup.tex.")

(ert-deftest bgt-document-definitions ()
  (should (equal (beamer-gui-document-definitions (list bgt-definitions-preamble))
                 '(:macros (("member" 3 . "40pt") ("logo" 0))
                   :environments (("varblock" . ".9\\textwidth"))))))

(ert-deftest bgt-scan-document-pictures ()
  (let ((beamer-gui--document-definitions
         (beamer-gui-document-definitions (list bgt-definitions-preamble))))
    (bgt-with (concat "\\begin{frame}{F}\n"
                      "\\member[30pt]{a.png}{Ada}{Lovelace} \\member{b.png}{Bo}{B}\n"
                      "\\movie[width=3cm]{poster}{film.mp4} \\tikzmark{m}\\hcancel{no} \\logo\n"
                      "\\begin{varblock}<2->[0.5\\textwidth]{T}x\\end{varblock}\n"
                      "\\end{frame}\n")
      (let ((elements (plist-get (beamer-gui-frame-model (point-min) (point-max)) :elements)))
        (should (equal (mapcar (lambda (e) (buffer-substring (plist-get e :beg) (plist-get e :end)))
                               elements)
                       '("\\member[30pt]{a.png}{Ada}{Lovelace}" "\\member{b.png}{Bo}{B}"
                         "\\movie[width=3cm]{poster}{film.mp4}" "\\logo"
                         "\\begin{varblock}<2->[0.5\\textwidth]{T}x\\end{varblock}")))
        (should (equal (mapcar (lambda (e) (beamer-gui--resize-mode (plist-get e :name)
                                                                    (plist-get e :inline)))
                               elements)
                       '("width" "width" "none" "none" "width")))))))

(ert-deftest bgt-resize-width-argument ()
  (let ((beamer-gui--document-definitions
         (beamer-gui-document-definitions (list bgt-definitions-preamble))))
    (should (equal (beamer-gui-resize-code "\\member[30pt]{a.png}{Ada}{L}" "member" 2 0.2)
                   "\\member[60pt]{a.png}{Ada}{L}"))
    (should (equal (beamer-gui-resize-code "\\member{a.png}{Ada}{L}" "member" 1.5 0.2)
                   "\\member[60pt]{a.png}{Ada}{L}"))
    (should (equal (beamer-gui-resize-code "\\begin{varblock}<2->[0.5\\textwidth]{T}x\\end{varblock}"
                                           "varblock" 0.5 0.2)
                   "\\begin{varblock}<2->[0.25\\textwidth]{T}x\\end{varblock}"))
    (should (equal (beamer-gui-resize-code "\\begin{varblock}{T}x\\end{varblock}" "varblock" 0.5 0.2)
                   "\\begin{varblock}[0.45\\textwidth]{T}x\\end{varblock}"))))


;;;; Failing gracefully

(defmacro bgt-with-file (text &rest body)
  "Run BODY in a buffer visiting a temporary .tex file holding TEXT."
  (declare (indent 1))
  `(let ((file (make-temp-file "bgt" nil ".tex" ,text)))
     (with-current-buffer (find-file-noselect file)
       (unwind-protect (progn (goto-char (point-min)) ,@body)
         (set-buffer-modified-p nil)
         (kill-buffer)))))

(defun bgt-check-error ()
  "Return the message of the `user-error' of the checks, or nil."
  (condition-case err (progn (beamer-gui--check-environment) nil)
    (user-error (cadr err))))

(ert-deftest bgt-check-buffer-and-class ()
  (with-temp-buffer
    (insert bgt-frame)
    (should (string-match-p "visit a file" (bgt-check-error))))
  (bgt-with-file "\\begin{frame}\nx\n\\end{frame}\n"
    (should (string-match-p "no \\\\documentclass" (bgt-check-error))))
  (bgt-with-file "\\documentclass{article}\n\\begin{document}\n\\begin{frame}\nx\n\\end{frame}\n"
    (search-forward "x")
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) nil)))
      (should (string-match-p "not a beamer document" (bgt-check-error))))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
      (should-not (bgt-check-error))))
  (bgt-with-file bgt-frame
    (should (string-match-p "point is not inside" (bgt-check-error)))
    (search-forward "Hello")
    (should-not (bgt-check-error))))

(ert-deftest bgt-check-tools ()
  (bgt-with-file bgt-frame
    (search-forward "Hello")
    (let ((beamer-gui-latex-command '("no-such-latex")))
      (should (string-match-p "no-such-latex. not found" (bgt-check-error))))
    (let ((beamer-gui-python "/no/such/python"))
      (should (string-match-p "Python ./no/such/python. not found" (bgt-check-error))))
    (let ((beamer-gui-script "/no/such/script.py"))
      (should (string-match-p "GUI script" (bgt-check-error))))))

(ert-deftest bgt-latex-error-message ()
  (let ((log (make-temp-file "bgt" nil ".log"
                             "This is pdfTeX\n! Undefined control sequence.\n<recently read> \\foo \n\nl.12 \\foo\n            bar\n")))
    (should (equal (beamer-gui--latex-error log) "Undefined control sequence. (at: \\foo)"))
    (should-not (beamer-gui--latex-error "/no/such.log"))))

(ert-deftest bgt-gui-stops-with-error ()
  "A GUI that fails at start (missing PySide6) is reported."
  (unless (executable-find "python3") (ert-skip "python3 missing"))
  (let ((messages nil) (done nil))
    (when (get-buffer "*beamer-gui-errors*") (kill-buffer "*beamer-gui-errors*"))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (make-process :name "bgt-gui" :command
                    '("python3" "-c" "import sys; sys.stderr.write(\"Traceback...\\nModuleNotFoundError: No module named 'PySide6'\\n\"); sys.exit(1)")
                    :stderr (get-buffer-create "*beamer-gui-errors*")
                    :sentinel (lambda (p e) (beamer-gui--gui-sentinel p e) (setq done t)))
      (with-timeout (20 (ert-fail "timeout"))
        (while (not done) (accept-process-output nil 0.1))))
    (should (cl-some (lambda (m) (string-match-p "editor stopped: ModuleNotFoundError: No module named 'PySide6'" m))
                     messages))))


;;;; Preamble, labels, mode

(ert-deftest bgt-insert-preamble-and-upgrade ()
  (bgt-with "\\documentclass{beamer}\n\\begin{document}\n\\end{document}\n"
    (beamer-gui-insert-preamble)
    (should (string-match-p "preamble 3\\(?:.\\|\n\\)*%%% ---\n\\\\begin{document}" (buffer-string)))
    (let ((once (buffer-string)))
      (beamer-gui-insert-preamble)
      (should (equal once (buffer-string)))))
  ;; Version 0.1 is replaced.
  (bgt-with (concat "\\documentclass{beamer}\n%% beamer-gui\n\\RequirePackage{tikz}\n"
                    "\\tikzset{gui arrow/.style={->},\n         gui ellipse/.style={red}}\n"
                    "\\begin{document}\n\\end{document}\n")
    (should (eql (beamer-gui--preamble-version (buffer-string)) 1))
    (beamer-gui-insert-preamble)
    (should (eql (beamer-gui--preamble-version (buffer-string)) 3))
    (should-not (string-match-p "^%% beamer-gui$" (buffer-string)))))

(ert-deftest bgt-label-frames ()
  (bgt-with bgt-frame
    (should (= (beamer-gui-label-frames) 3))
    (should (string-match-p "\\\\begin{frame}\\[fragile,label=fr:first-slide-2\\]{First slide}"
                            (buffer-string)))
    (should (= (beamer-gui-label-frames) 0))))

(ert-deftest bgt-mode-key ()
  (with-temp-buffer
    (beamer-gui-mode 1)
    (should (eq (key-binding (kbd "C-c M-g")) #'beamer-gui-edit-frame))
    (beamer-gui-mode -1)
    (should-not (eq (key-binding (kbd "C-c M-g")) #'beamer-gui-edit-frame))))


;;;; Org

(defconst bgt-org
  "#+LATEX_CLASS: beamer
#+OPTIONS: toc:nil H:1
* Frame A
text A
* Frame B
%%% beamer-gui img1
\\begin{textblock*}{0.3\\paperwidth}(0.1\\paperwidth,0.2\\paperheight)
  \\includegraphics[width=\\linewidth]{fig_slides/b.png}
\\end{textblock*}
%%% ---
more B
* Frame C
"
  "Org beamer document with a block in its second frame.")

(ert-deftest bgt-org-apply ()
  (with-temp-buffer
    (org-mode)
    (insert bgt-org)
    (goto-char (point-min))
    (let* ((b (bgt-frame-at "more B"))
           (model (beamer-gui-frame-model (car b) (cdr b) t)))
      (should (equal (bgt-ids (plist-get model :blocks)) '("img1")))
      (beamer-gui-apply-items
       (car b) (cdr b)
       (list (plist-put (beamer-gui--item-data (car (plist-get model :blocks))) :y 0.5)
             '(:id "arrow1" :kind "arrow" :x1 0.1 :y1 0.1 :x2 0.2 :y2 0.2 :opts "")))
      (should (string-match-p "(0.1\\\\paperwidth,0.5\\\\paperheight)" (buffer-string)))
      (should (string-match-p "%%% ---\n\\* Frame C" (buffer-string))))))


;;;; Compilation (pdflatex)

(ert-deftest bgt-compile-measure-document ()
  "The measuring document of a real frame compiles and records marks."
  (bgt-with (string-replace "\\begin{document}"
                            (concat beamer-gui-preamble "\\begin{document}")
                            (replace-regexp-in-string "fig_slides/[ab].png" "example-image"
                                                      bgt-frame))
    (pcase-let* ((`(,pre ,setup ,frame) (beamer-gui--frame-parts (car (bgt-frame-at "Hello"))))
                 (`(,_pdf . ,out) (bgt-compile (beamer-gui-measure-document
                                                pre setup frame '("red" "blue")))))
      (let ((m (beamer-gui-measurements (expand-file-name "frame.bgpos" out))))
        (should (equal (plist-get m :page-b) (1+ (* 2 (plist-get m :page-a)))))
        (dolist (id '("c1" "c2" "c3"))
          (should (beamer-gui--measured id m)))
        (should (equal (mapcar #'car (plist-get m :colors)) '("red" "blue")))))))

(ert-deftest bgt-end-to-end-fake-gui ()
  "Edit, compile, GUI save, buffer updated, new session sent."
  (unless (executable-find "pdflatex") (ert-skip "pdflatex missing"))
  (let* ((dir (file-name-as-directory (make-temp-file "bgt-e2e" t)))
         (file (expand-file-name "s.tex" dir))
         (done (expand-file-name "done.txt" dir))
         (beamer-gui-script (expand-file-name "fake_gui.py" bgt-dir)))
    (with-temp-file file
      (insert (string-replace "\\begin{document}"
                              (concat beamer-gui-preamble "\\begin{document}")
                              (replace-regexp-in-string "fig_slides/[ab].png" "example-image"
                                                        bgt-frame))))
    (with-current-buffer (find-file-noselect file)
      (unwind-protect
          (progn
            (bgt-frame-at "Hello")
            (beamer-gui-edit-frame)
            (with-timeout (90 (ert-fail "Timeout"))
              (while (not (file-exists-p done)) (accept-process-output nil 0.2)))
            (let ((text (buffer-string)))
              (should (string-match-p "(0.5\\\\paperwidth,0.15\\\\paperheight)" text))
              (should (string-match-p "%%% beamer-gui arrow9" text))
              (should (string-match-p "% gui:arrow1" text)))    ; unchanged, untouched
            (should (string-match-p "\"session\"" (with-temp-buffer
                                                     (insert-file-contents done)
                                                     (buffer-string)))))
        (set-buffer-modified-p nil)
        (kill-buffer)))))

(provide 'beamer-gui-test)
;;; beamer-gui-test.el ends here
