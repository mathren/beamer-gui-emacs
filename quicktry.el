;;; quicktry.el --- Try beamer-gui in emacs -Q  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Mathieu Renzo

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Development tool, not part of the package (exclude it from the
;; MELPA recipe).  From the repository root:
;;
;;   emacs -Q -l quicktry.el
;;
;; It loads beamer-gui from this directory, picks the Python of the
;; conda environment `beamer-gui' (see environment.yml) when it exists,
;; and opens a sample deck in a fresh temporary directory.  Put point
;; in the frame and run M-x beamer-gui-edit-frame.
;;
;; Override the interpreter with the environment variable
;; BEAMER_GUI_PYTHON.

;;; Code:

(defconst quicktry-dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory of beamer-gui.")

(add-to-list 'load-path quicktry-dir)
(require 'beamer-gui)

(defun quicktry-python ()
  "Return the Python to use: $BEAMER_GUI_PYTHON, the conda env, or python3."
  (or (getenv "BEAMER_GUI_PYTHON")
      (let* ((conda (or (executable-find "conda") (executable-find "mamba")))
             (base (and conda (string-trim
                               (shell-command-to-string
                                (concat (shell-quote-argument conda) " info --base")))))
             (python (and base (expand-file-name "envs/beamer-gui/bin/python" base))))
        (and python (file-executable-p python) python))
      "python3"))

(defun quicktry-check-python (python)
  "Warn if PYTHON lacks PySide6 or PyMuPDF."
  (unless (eq 0 (ignore-errors
                  (call-process python nil nil nil "-c" "import PySide6, pymupdf")))
    (display-warning 'beamer-gui
                     (format "%s cannot import PySide6 and pymupdf; run \
`conda env create -f environment.yml' or set BEAMER_GUI_PYTHON" python))))

(defconst quicktry-sample
  "\\documentclass[aspectratio=169]{beamer}
\\usepackage{pgfpages}
%% Notes for pdfpc: the editor ignores this option.
%% \\setbeameroption{show notes on second screen=right}
%% beamer-gui
\\RequirePackage{tikz}
\\makeatletter\\@ifpackageloaded{textpos}{}{\\usepackage[absolute,overlay]{textpos}}\\makeatother
\\tikzset{gui arrow/.style={->,>=stealth,line width=2pt,red},
         gui ellipse/.style={line width=2pt,red}}
\\begin{document}
\\begin{frame}{Try beamer-gui}
  Put point here and run \\texttt{M-x beamer-gui-edit-frame}.
\\begin{textblock*}{0.35\\paperwidth}(0.55\\paperwidth,0.3\\paperheight) % gui:img1
  \\includegraphics[width=\\linewidth]{fig_slides/example.pdf}
\\end{textblock*}
\\begin{textblock*}{0.25\\paperwidth}(0.2\\paperwidth,0.55\\paperheight) % gui:arrow1
  \\tikz[x=\\paperwidth,y=\\paperheight]{\\useasboundingbox (0,0) rectangle (0.25,-0.1); \\draw[gui arrow,overlay] (0,-0.1) -- (0.25,-0);}
\\end{textblock*}
  \\note{A note for the second screen.}
\\end{frame}
\\end{document}
"
  "Sample deck with an image and an arrow.")

(defun quicktry-open-sample ()
  "Write the sample deck in a temporary directory and visit it."
  (let* ((dir (file-name-as-directory (make-temp-file "beamer-gui-try" t)))
         (figures (expand-file-name beamer-gui-image-dir-name dir))
         (image (string-trim (shell-command-to-string "kpsewhich example-image-a.pdf"))))
    (make-directory figures)
    (if (file-exists-p image)
        (copy-file image (expand-file-name "example.pdf" figures))
      (display-warning 'beamer-gui "example-image-a.pdf (mwe package) not found"))
    (with-temp-file (expand-file-name "sample.tex" dir)
      (insert quicktry-sample))
    (find-file (expand-file-name "sample.tex" dir))
    (search-forward "Put point here")
    (message "Run M-x beamer-gui-edit-frame (Ctrl+S in the editor saves; see %s)" dir)))

(setq beamer-gui-python (quicktry-python))
(quicktry-check-python beamer-gui-python)
(quicktry-open-sample)

;;; quicktry.el ends here
