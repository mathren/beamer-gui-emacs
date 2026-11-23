;;; beamer-gui.el --- Edit the elements of beamer frames graphically  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Mathieu Renzo

;; Author: Mathieu Renzo
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tex, tools, multimedia
;; URL: https://github.com/mathren/beamer-gui-emacs

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Edit the elements of the beamer frame at point in a Qt window:
;; move and resize images, blocks, tcolorboxes, textblocks and other
;; environments; add arrows, ellipses, rectangles and text with a
;; colour palette and line styles; paste images.
;;
;; Code written or changed by the editor is framed by two comment
;; lines, so it is easy to find and edit by hand:
;;
;;   %%% beamer-gui arrow1
;;   \begin{textblock*}{0.2\paperwidth}(0.5\paperwidth,0.4\paperheight)
;;     \tikz[...]{... \draw[gui arrow, draw=Maroon, very thick] ...;}
;;   \end{textblock*}
;;   %%% ---
;;
;; An element of the text flow (an \includegraphics, a block...) that
;; is moved is wrapped, unchanged, in a textblock* placed where it was
;; dragged, followed by a spacer of its original size, so nothing else
;; on the slide moves.  `beamer-gui-unwrap' puts it back in the flow.
;;
;; Positions are measured by LaTeX itself: the frame is compiled with
;; invisible markers that record where each element is.
;;
;; Entry point: `beamer-gui-edit-frame', bound to C-c M-g in
;; `beamer-gui-mode', a minor mode to enable in LaTeX buffers.  Run
;; `beamer-gui-insert-preamble' once per document, and set
;; `beamer-gui-python' to a Python with PySide6 and PyMuPDF.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function org-back-to-heading "org" (&optional invisible-ok))
(declare-function org-end-of-subtree "org" (&optional invisible-ok to-heading))
(declare-function org-export-as "ox"
                  (backend &optional subtreep visible-only body-only ext-plist))


;;;; Customization

(defgroup beamer-gui nil
  "Graphical editing of beamer frames."
  :group 'tex
  :prefix "beamer-gui-")

(defcustom beamer-gui-image-dir-name "fig_slides"
  "Directory, relative to the source file, where pasted images are saved."
  :type 'string)

(defcustom beamer-gui-python "python3"
  "Python interpreter that runs the GUI.
It must provide PySide6 and PyMuPDF 1.24 or later, for example the
python of the conda environment of environment.yml.  A command name
is looked up in the variable `exec-path'; a file name is used as is."
  :type '(file :tag "Interpreter or command"))

(defcustom beamer-gui-script
  (expand-file-name "beamer_gui.py"
                    (file-name-directory (or load-file-name buffer-file-name
                                             default-directory)))
  "File name of the Qt GUI script."
  :type 'file)

(defcustom beamer-gui-latex-command
  '("pdflatex" "-interaction=nonstopmode" "-halt-on-error")
  "Command compiling a single frame.
The output directory option and the file name are appended."
  :type '(repeat string))

(defcustom beamer-gui-body-setup-regexp
  "^[ \t]*\\\\\\(?:graphicspath\\|tikzset\\|tikzstyle\\|setbeamer[a-z]+\\){"
  "Regexp for setup commands copied into single-frame documents.
Matching commands between \\begin{document} and the first frame,
such as \\graphicspath, are kept.  The match must end at the
opening brace of the command argument."
  :type 'regexp)

(defcustom beamer-gui-container-environments
  '("columns" "column" "center" "flushleft" "flushright" "minipage"
    "onlyenv" "uncoverenv" "visibleenv" "invisibleenv" "actionenv"
    "alertenv" "structureenv" "altenv" "overlayarea" "overprint")
  "Environments whose content is scanned for movable elements.
They are not movable themselves."
  :type '(repeat string))

(defcustom beamer-gui-ignored-environments
  '("frame" "verbatim" "verbatim*" "semiverbatim" "lstlisting" "minted"
    "comment")
  "Environments that are neither movable nor scanned."
  :type '(repeat string))

(defcustom beamer-gui-inline-environments
  '("tabular" "tabular*" "tabularx" "array" "tikzpicture")
  "Movable environments set inside a line, like a character.
Other movable environments are set between paragraphs, like a
block.  Any environment in a frame that is not in
`beamer-gui-container-environments' or
`beamer-gui-ignored-environments' is movable, which includes all
those AUCTeX offers in a beamer frame."
  :type '(repeat string))

(defcustom beamer-gui-movable-macros '("includegraphics")
  "Macros movable like an image.
Each takes optional <overlay> and [options] arguments and one
mandatory argument."
  :type '(repeat string))


;;;; Constants

(defconst beamer-gui--preamble-version 3
  "Version of `beamer-gui-preamble'; older ones are replaced.")

(defconst beamer-gui-preamble
  "%%% beamer-gui preamble 3
\\RequirePackage{tikz}
\\makeatletter\\@ifpackageloaded{textpos}{}{\\usepackage[absolute,overlay]{textpos}}\\makeatother
% Base styles of the shapes; each shape adds colour and style options.
\\tikzset{gui arrow/.style={->, >=stealth, line width=2pt, draw=red, overlay},
         gui ellipse/.style={line width=2pt, draw=red},
         gui rect/.style={line width=2pt, draw=red},
         gui text/.style={text width=\\linewidth, inner sep=0pt,
                          anchor=north west, align=left}}
% Keep the space of an element moved out of the text flow: its
% height, the depth of its last line and the skip that followed it.
\\providecommand\\beamerguivspace[3]{\\par\\vspace*{#1}\\prevdepth=#2\\relax\\vskip#3\\relax}
% Inside a moved element's textblock*: the skip and line depth that
% preceded it in the text, so that it is spaced as it was there.
\\providecommand\\beamerguicontext[2]{\\vskip#1\\relax\\prevdepth=#2\\relax}
\\providecommand\\beamerguihspace[3]{\\leavevmode\\hbox to #1{\\vrule height #2 depth #3 width 0pt\\hss}}
%%% ---
"
  "Preamble lines required by elements written by beamer-gui.")

(defconst beamer-gui--measure-preamble
  "\\makeatletter
\\newwrite\\bg@out
\\immediate\\openout\\bg@out=\\jobname.bgpos
\\ifdefined\\pdfsavepos
  \\let\\bg@savepos\\pdfsavepos\\def\\bg@x{\\the\\pdflastxpos}\\def\\bg@y{\\the\\pdflastypos}
\\else
  \\let\\bg@savepos\\savepos\\def\\bg@x{\\the\\lastxpos}\\def\\bg@y{\\the\\lastypos}
\\fi
\\newskip\\bg@skip
\\newsavebox\\bg@box
\\def\\bg@extra{}
\\def\\bg@modules{\\ifdefined\\TPHorizModule hm=\\the\\TPHorizModule\\space vm=\\the\\TPVertModule\\fi}
\\newcommand\\bg@write[2]{\\edef\\bg@w{\\write\\bg@out{#1 #2 page=\\noexpand\\thepage\\space
  x=\\noexpand\\bg@x\\space y=\\noexpand\\bg@y\\space lw=\\the\\linewidth\\space
  tw=\\the\\textwidth\\space\\bg@modules\\space\\bg@extra}}\\bg@savepos\\bg@w}
% Vertical mark: keeps \\lastskip, so that \\addvspace still works.
\\newcommand\\bgmarkv[2]{\\par\\bg@skip=\\lastskip\\ifdim\\bg@skip=\\z@\\else\\unskip\\fi
  \\edef\\bg@extra{pd=\\the\\prevdepth\\space ls=\\the\\bg@skip}\\bg@write{#1}{#2}\\def\\bg@extra{}%
  \\ifdim\\bg@skip=\\z@\\else\\vskip\\bg@skip\\fi}
% Inline element: measure its box, then set it.
% (lrbox closes its box after the environment group: measure after it.)
\\newenvironment{bgmeasure}[1]{\\gdef\\bg@id{#1}\\lrbox\\bg@box}{\\endlrbox\\aftergroup\\bg@inline}
\\def\\bg@inline{\\leavevmode
  \\edef\\bg@extra{wd=\\the\\wd\\bg@box\\space ht=\\the\\ht\\bg@box\\space dp=\\the\\dp\\bg@box}%
  \\bg@write{\\bg@id}{i}\\def\\bg@extra{}\\usebox\\bg@box}
\\newcommand\\bgswatch[1]{\\leavevmode\\bg@write{color:#1}{s}\\textcolor{#1}{\\rule{3mm}{3mm}}\\hspace{1mm}\\allowbreak}
\\AtBeginDocument{\\immediate\\write\\bg@out{@paper p pw=\\the\\paperwidth\\space ph=\\the\\paperheight}}
\\makeatother
"
  "Macros recording element positions, added to compiled copies only.")

(defconst beamer-gui--document-begin-regexp "^[ \t]*\\\\begin{document}")
(defconst beamer-gui--frame-begin-regexp "^[ \t]*\\\\begin{frame}")
(defconst beamer-gui--frame-end-regexp "\\\\end{frame}")
(defconst beamer-gui--org-heading-regexp "^\\*+ ")

(defconst beamer-gui--notes-regexp
  "^[ \t]*\\\\setbeameroption{[ \t]*show \\(?:only \\)?notes[^}]*}"
  "Regexp for beamer options adding note pages or a second screen.")

(defconst beamer-gui--id-regexp "[[:alnum:]_-]+"
  "Regexp for element identifiers.")

(defconst beamer-gui--number "-?[0-9]*\\.?[0-9]+"
  "Regexp matching a decimal number.")

(defconst beamer-gui--number-group (concat "\\(" beamer-gui--number "\\)")
  "Regexp group matching a decimal number.")

(defconst beamer-gui--header-regexp
  (concat "^[ \t]*%%% beamer-gui \\(" beamer-gui--id-regexp "\\)\\([^\n]*\\)$")
  "Regexp for the first comment line of a block.
Groups: 1 identifier, 2 the rest of the line.")

(defconst beamer-gui--footer-regexp "^[ \t]*%%% ---[ \t]*$"
  "Regexp for the last comment line of a block.")

(defconst beamer-gui--wrapper-regexp
  (let ((n beamer-gui--number-group))
    (concat "\\\\begin{textblock\\*}{" n "\\\\paperwidth}"
            "(" n "\\\\paperwidth," n "\\\\paperheight)"))
  "Regexp for the textblock* line written by beamer-gui.
Groups: 1 width, 2 x, 3 y, as page fractions.")

(defconst beamer-gui--legacy-regexp
  (let ((n beamer-gui--number-group))
    (concat "\\\\begin{textblock\\*}{" n "\\\\paperwidth}"
            "(" n "\\\\paperwidth," n "\\\\paperheight)"
            "[ \t]*%[ \t]*gui:\\(" beamer-gui--id-regexp "\\)[^\n]*\n"
            "\\(\\(?:.\\|\n\\)*?\\)[ \t]*\\\\end{textblock\\*}"))
  "Regexp for a block of version 0.1, tagged by a trailing comment.
Groups: 1 width, 2 x, 3 y, 4 identifier, 5 body.")

(defconst beamer-gui--image-regexp
  "\\`[ \t\n]*\\\\includegraphics\\[width=\\\\linewidth\\]{\\([^}]+\\)}[ \t\n]*\\'"
  "Regexp for an image body.  Group 1 is the file name.")

(defconst beamer-gui--paren-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?{ "(}" table)
    (modify-syntax-entry ?} "){" table)
    (modify-syntax-entry ?\[ "(]" table)
    (modify-syntax-entry ?\] ")[" table)
    (modify-syntax-entry ?\( "." table)
    (modify-syntax-entry ?\) "." table)
    (modify-syntax-entry ?\\ "\\" table)
    table)
  "Syntax table in which only braces and brackets group.")

(defconst beamer-gui--base-colors
  '("red" "green" "blue" "cyan" "magenta" "yellow" "black" "gray" "white"
    "darkgray" "lightgray" "brown" "lime" "olive" "orange" "pink" "purple"
    "teal" "violet")
  "Colours always defined by xcolor.")

(defconst beamer-gui--dvipsnames
  '("Apricot" "Aquamarine" "Bittersweet" "Black" "Blue" "BlueGreen"
    "BlueViolet" "BrickRed" "Brown" "BurntOrange" "CadetBlue"
    "CarnationPink" "Cerulean" "CornflowerBlue" "Cyan" "Dandelion"
    "DarkOrchid" "Emerald" "ForestGreen" "Fuchsia" "Goldenrod" "Gray"
    "Green" "GreenYellow" "JungleGreen" "Lavender" "LimeGreen" "Magenta"
    "Mahogany" "Maroon" "Melon" "MidnightBlue" "Mulberry" "NavyBlue"
    "OliveGreen" "Orange" "OrangeRed" "Orchid" "Peach" "Periwinkle"
    "PineGreen" "Plum" "ProcessBlue" "Purple" "RawSienna" "Red"
    "RedOrange" "RedViolet" "Rhodamine" "RoyalBlue" "RoyalPurple"
    "RubineRed" "Salmon" "SeaGreen" "Sepia" "SkyBlue" "SpringGreen" "Tan"
    "TealBlue" "Thistle" "Turquoise" "Violet" "VioletRed" "White"
    "WildStrawberry" "Yellow" "YellowGreen" "YellowOrange")
  "Colours of the xcolor option dvipsnames.")

(defconst beamer-gui--length-units
  '(("pt" . 1.0) ("bp" . 1.00375) ("mm" . 2.84528) ("cm" . 28.45276)
    ("in" . 72.27) ("pc" . 12.0))
  "Absolute TeX units, in points.")


;;;; Utilities

(defun beamer-gui--org-p ()
  "Return non-nil if the current buffer is an Org buffer."
  (derived-mode-p 'org-mode))

(defun beamer-gui--fmt (x &optional decimals)
  "Return number X as a string with at most DECIMALS decimals (default 4)."
  (let ((s (string-trim-right (format (format "%%.%df" (or decimals 4)) x)
                              "\\.?0+")))
    (if (member s '("" "-0")) "0" s)))

(defun beamer-gui--pt (x)
  "Return length X in points as TeX text, two decimals."
  (concat (beamer-gui--fmt x 2) "pt"))

(defun beamer-gui--match-numbers (string &rest groups)
  "Return the numbers matched by GROUPS of the last match.
STRING is the string searched, or nil for the buffer."
  (mapcar (lambda (g) (string-to-number (match-string g string))) groups))

(defun beamer-gui--item-data (item)
  "Return ITEM without its buffer positions."
  (cl-loop for (key value) on item by #'cddr
           unless (memq key '(:beg :end :code-beg :code-end :head-beg :head-end
                                   :inner-beg :inner-end :wrapper-end))
           append (list key value)))

(defun beamer-gui--skip-group ()
  "Move over the balanced {...} or [...] group after point, if any.
Return non-nil if a group was skipped."
  (when (memq (char-after) '(?{ ?\[))
    (with-syntax-table beamer-gui--paren-syntax-table
      (forward-sexp))
    t))

(defun beamer-gui--skip-overlay ()
  "Move over an <overlay specification> after point, if any."
  (when (looking-at "<[^>\n]*>")
    (goto-char (match-end 0))))

(defun beamer-gui--escaped-p (pos)
  "Return non-nil if the character at POS is escaped by a backslash."
  (save-excursion
    (goto-char pos)
    (cl-oddp (- (point) (progn (skip-chars-backward "\\\\") (point))))))


;;;; Blocks written by beamer-gui: parsing

(defun beamer-gui--styled (body command style)
  "Find COMMAND[STYLE, ...] in BODY.
Return (OPTIONS . REST): the options after STYLE, as a string, and
the text after the closing bracket; or nil."
  (with-temp-buffer
    (insert body)
    (goto-char (point-min))
    (when (search-forward (concat command "[" style) nil t)
      (let* ((open (- (point) (length style) 1))
             (close (progn (goto-char open)
                           (with-syntax-table beamer-gui--paren-syntax-table
                             (forward-sexp))
                           (point)))
             (inside (buffer-substring (1+ open) (1- close)))
             (opts (string-trim (substring inside (length style)))))
        (setq opts (string-trim (string-remove-prefix "," opts)))
        ;; Version 0.1 put overlay here; the style now has it.
        (when (equal opts "overlay") (setq opts ""))
        (cons opts (buffer-substring close (point-max)))))))

(defun beamer-gui--parse-body (body x y w)
  "Return the element plist for BODY of a block at X, Y of width W."
  (let ((case-fold-search nil)
        (n beamer-gui--number-group)
        found)
    (cond
     ((string-match beamer-gui--image-regexp body)
      (list :kind "image" :x x :y y :w w :file (match-string 1 body)))
     ((and (setq found (beamer-gui--styled body "\\draw" "gui arrow"))
           (string-match (concat "\\` *(" n ",-" n ") \\(?:--\\|to\\) (" n ",-" n ")")
                         (cdr found)))
      (pcase-let ((`(,x1 ,y1 ,x2 ,y2) (beamer-gui--match-numbers (cdr found) 1 2 3 4)))
        (list :kind "arrow" :x1 (+ x x1) :y1 (+ y y1) :x2 (+ x x2) :y2 (+ y y2)
              :opts (car found))))
     ((and (setq found (beamer-gui--styled body "\\draw" "gui ellipse"))
           (string-match (concat "\\` *(" n ",-" n ") ellipse\\[x radius=" n
                                 ",y radius=" n "\\]")
                         (cdr found)))
      (pcase-let ((`(,rx ,ry) (beamer-gui--match-numbers (cdr found) 3 4)))
        (list :kind "ellipse" :x x :y y :w (* 2 rx) :h (* 2 ry) :opts (car found))))
     ((and (setq found (beamer-gui--styled body "\\draw" "gui rect"))
           (string-match (concat "\\` *(0,0) rectangle (" n ",-" n ")") (cdr found)))
      (pcase-let ((`(,rw ,rh) (beamer-gui--match-numbers (cdr found) 1 2)))
        (list :kind "rect" :x x :y y :w rw :h rh :opts (car found))))
     ((and (setq found (beamer-gui--styled body "\\node" "gui text"))
           (string-match "\\` *{" (cdr found)))
      (let ((rest (cdr found)))
        (with-temp-buffer
          (insert rest)
          (goto-char (point-min))
          (skip-chars-forward " ")
          (let ((open (point)))
            (beamer-gui--skip-group)
            (list :kind "text" :x x :y y :w w :opts (car found)
                  :text (buffer-substring (1+ open) (1- (point))))))))
     (t
      (list :kind "raw" :x x :y y :w w :body (string-trim body))))))

(defun beamer-gui--parse-wrapper ()
  "Parse the beamer-gui textblock* line at point; return (W X Y) or nil."
  (when (looking-at (concat "[ \t]*" beamer-gui--wrapper-regexp))
    (beamer-gui--match-numbers nil 1 2 3)))

(defun beamer-gui--parse-framed (extra beg end)
  "Return the plist of the framed block with header rest EXTRA.
Its body runs from BEG to END, the start of the footer line."
  (save-excursion
    (goto-char beg)
    (cond
     ((string-match "(moved \\([^)]+\\))" extra)
      ;; The spacer may precede the wrapper (inline elements) or follow it.
      (let* ((name (match-string 1 extra))
             (wxy (progn (re-search-forward (concat "^[ \t]*" beamer-gui--wrapper-regexp) end)
                         (beamer-gui--match-numbers nil 1 2 3)))
             (head-beg (line-beginning-position))
             (head-end (progn (forward-line 1) (point)))
             (code-beg (progn (while (looking-at ".*% as \\(?:outside the block\\|in the text\\)$")
                                (forward-line 1))
                              (point)))
             (code-end (progn (goto-char end)
                              (re-search-backward "^[ \t]*\\\\end{textblock\\*}" code-beg)
                              (point))))
        (list :kind "wrap" :moved name :w (nth 0 wxy) :x (nth 1 wxy) :y (nth 2 wxy)
              :head-beg head-beg :head-end head-end
              :code-beg code-beg :code-end code-end
              :wrapper-end (progn (forward-line 1) (point))
              :inline (beamer-gui--inline-name-p name))))
     ((string-match "(textblock)" extra)
      (list :kind "textblock" :inner-beg beg :inner-end end
            :name (save-excursion
                    (goto-char beg)
                    (if (re-search-forward "\\\\begin{\\(textblock\\*?\\)}" end t)
                        (match-string-no-properties 1)
                      "textblock"))))
     (t
      (pcase-let ((`(,w ,x ,y) (or (beamer-gui--parse-wrapper) '(0 0 0))))
        (forward-line 1)
        (let ((inner-beg (point))
              (inner-end (progn (goto-char end)
                                (re-search-backward "^[ \t]*\\\\end{textblock\\*}" beg t)
                                (point))))
          (beamer-gui--parse-body (buffer-substring-no-properties inner-beg inner-end)
                                  x y w)))))))

(defun beamer-gui-parse-blocks (beg end)
  "Return the blocks written by beamer-gui between BEG and END.
Each is a plist with :id, :kind, the geometry of that kind, and the
buffer positions :beg and :end.  Blocks of version 0.1, tagged
with a trailing % gui:ID comment, have :legacy t."
  (save-excursion
    (let (blocks)
      (goto-char beg)
      (while (re-search-forward beamer-gui--header-regexp end t)
        (let ((id (match-string-no-properties 1))
              (extra (match-string-no-properties 2))
              (b (match-beginning 0))
              (body-beg (min end (1+ (match-end 0)))))
          (when (re-search-forward beamer-gui--footer-regexp end t)
            (let ((e (match-end 0)))
              (push (append (list :id id :beg b :end e)
                            (beamer-gui--parse-framed
                             extra body-beg (match-beginning 0)))
                    blocks)))))
      (goto-char beg)
      (while (re-search-forward beamer-gui--legacy-regexp end t)
        (pcase-let ((`(,w ,x ,y) (beamer-gui--match-numbers nil 1 2 3)))
          (unless (cl-some (lambda (b) (<= (plist-get b :beg) (match-beginning 0)
                                           (plist-get b :end)))
                           blocks)
            (push (append (list :id (match-string-no-properties 4) :legacy t
                                :beg (match-beginning 0) :end (match-end 0))
                          (beamer-gui--parse-body (match-string-no-properties 5) x y w))
                  blocks))))
      (sort blocks (lambda (a b) (< (plist-get a :beg) (plist-get b :beg)))))))


;;;; Blocks written by beamer-gui: serialization

(defun beamer-gui--framed (id extra body &optional indent)
  "Return BODY framed by the comment lines of block ID.
EXTRA, if non-nil, is added to the first line.  The comment lines
are indented by INDENT."
  (let ((indent (or indent "")))
    (concat indent "%%% beamer-gui " id (if extra (concat " " extra) "") "\n"
            body (if (string-suffix-p "\n" body) "" "\n")
            indent "%%% ---")))

(defun beamer-gui--wrapper (x y w)
  "Return the textblock* line of width W at X, Y, all page fractions."
  (format "\\begin{textblock*}{%s\\paperwidth}(%s\\paperwidth,%s\\paperheight)"
          (beamer-gui--fmt w) (beamer-gui--fmt x) (beamer-gui--fmt y)))

(defun beamer-gui--style (style opts)
  "Return the TikZ option list STYLE followed by OPTS, if any."
  (if (string-empty-p (or opts "")) style (concat style ", " opts)))

(defun beamer-gui--tikz (w h draw)
  "Return a TikZ picture of size W by H page fractions running DRAW."
  (format "\\tikz[x=\\paperwidth,y=\\paperheight]{\\useasboundingbox (0,0) rectangle (%s,-%s); %s;}"
          (beamer-gui--fmt w) (beamer-gui--fmt h) draw))

(defun beamer-gui-item-to-tex (item)
  "Return the framed LaTeX block for the drawn element ITEM.
ITEM has :kind image, arrow, ellipse, rect, text or raw."
  (let ((id (plist-get item :id))
        (f #'beamer-gui--fmt))
    (unless (and (stringp id)
                 (string-match-p (concat "\\`" beamer-gui--id-regexp "\\'") id))
      (error "Invalid element id: %S" id))
    (cl-flet ((block (x y w inner)
                (beamer-gui--framed
                 id nil (concat (beamer-gui--wrapper x y w) "\n  " inner
                                "\n\\end{textblock*}"))))
      (pcase (plist-get item :kind)
        ("image"
         (block (plist-get item :x) (plist-get item :y) (plist-get item :w)
                (format "\\includegraphics[width=\\linewidth]{%s}" (plist-get item :file))))
        ("arrow"
         ;; The block is the bounding box of the arrow.
         (cl-destructuring-bind (&key x1 y1 x2 y2 opts &allow-other-keys) item
           (let ((x (min x1 x2)) (y (min y1 y2))
                 (w (max (abs (- x2 x1)) 0.001)) (h (max (abs (- y2 y1)) 0.001)))
             (block x y w
                    (beamer-gui--tikz
                     w h (format "\\draw[%s] (%s,-%s) to (%s,-%s)"
                                 (beamer-gui--style "gui arrow" opts)
                                 (funcall f (- x1 x)) (funcall f (- y1 y))
                                 (funcall f (- x2 x)) (funcall f (- y2 y))))))))
        ("ellipse"
         (cl-destructuring-bind (&key x y w h opts &allow-other-keys) item
           (let ((rx (funcall f (/ w 2.0))) (ry (funcall f (/ h 2.0))))
             (block x y w
                    (beamer-gui--tikz
                     w h (format "\\draw[%s] (%s,-%s) ellipse[x radius=%s,y radius=%s]"
                                 (beamer-gui--style "gui ellipse" opts) rx ry rx ry))))))
        ("rect"
         (cl-destructuring-bind (&key x y w h opts &allow-other-keys) item
           (block x y w
                  (beamer-gui--tikz
                   w h (format "\\draw[%s] (0,0) rectangle (%s,-%s)"
                               (beamer-gui--style "gui rect" opts)
                               (funcall f w) (funcall f h))))))
        ("text"
         (block (plist-get item :x) (plist-get item :y) (plist-get item :w)
                (format "\\tikz\\node[%s] {%s};"
                        (beamer-gui--style "gui text" (plist-get item :opts))
                        (plist-get item :text))))
        ("raw"
         (block (plist-get item :x) (plist-get item :y) (plist-get item :w)
                (string-trim (plist-get item :body))))
        (kind (error "Unknown element kind: %S" kind))))))


;;;; Movable elements of the text flow

(defconst beamer-gui--textblock-head-regexp
  (concat "\\\\begin{\\(textblock\\*?\\)}[ \t]*{\\([^}]*\\)}[ \t]*"
          "\\(?:\\[[^]]*\\][ \t]*\\)?(\\([^,)]*\\),\\([^)]*\\))")
  "Regexp for the first line of a textblock.
Groups: 1 environment, 2 width, 3 x, 4 y.")

(defun beamer-gui--inline-name-p (name)
  "Return non-nil if the element NAME is set inside a line."
  (or (member name beamer-gui-inline-environments)
      (member name beamer-gui-movable-macros)))

(defun beamer-gui--env-end (name)
  "Move after the \\end{NAME} matching the \\begin{NAME} before point.
Return point.  Comments are skipped."
  (let ((depth 1)
        (regexp (concat "\\\\\\(begin\\|end\\){" (regexp-quote name) "}\\|%")))
    (while (and (> depth 0) (re-search-forward regexp nil t))
      (cond ((not (match-beginning 1))
             (unless (beamer-gui--escaped-p (match-beginning 0))
               (forward-line 1)))
            ((equal (match-string 1) "begin") (cl-incf depth))
            (t (cl-decf depth))))
    (when (> depth 0)
      (error "No \\end{%s}" name))
    (point)))

(defun beamer-gui--frame-body (beg end)
  "Return (BODY-BEG . BODY-END) of the frame from BEG to END.
The body starts after \\begin{frame} and its arguments on the same line."
  (save-excursion
    (goto-char beg)
    (re-search-forward "\\\\begin{frame}")
    (while (progn (skip-chars-forward " \t")
                  (or (beamer-gui--skip-overlay) (beamer-gui--skip-group))))
    (cons (point)
          (progn (goto-char end)
                 (search-backward "\\end{frame}" beg)
                 (point)))))

(defun beamer-gui-scan-elements (beg end &optional blocks)
  "Return the movable elements of the text between BEG and END.
BLOCKS are the beamer-gui blocks there, which are skipped.  Each
element is a plist with :id (c1, c2... in order), :kind \"flow\"
or \"textblock\", :name (environment or macro), :beg, :end, and
:inline for flow elements."
  (save-excursion
    (let ((n 0) elements)
      (cl-flet ((add (plist)
                  (push (append (list :id (format "c%d" (cl-incf n))) plist) elements)))
        (goto-char beg)
        (while (re-search-forward
                "%\\|\\\\begin{\\([^}\n]+\\)}\\|\\\\\\([a-zA-Z]+\\)" end t)
          (let* ((start (match-beginning 0))
                 (env (match-string-no-properties 1))
                 (macro (match-string-no-properties 2))
                 (block (cl-find-if (lambda (b) (<= (plist-get b :beg) start
                                                    (1- (plist-get b :end))))
                                    blocks)))
            (cond
             (block (goto-char (plist-get block :end)))
             ((and (not env) (not macro))      ; a comment
              (unless (beamer-gui--escaped-p start)
                (forward-line 1)))
             (macro
              (when (member macro beamer-gui-movable-macros)
                (when (eq (char-after) ?*) (forward-char))
                (beamer-gui--skip-overlay)
                (beamer-gui--skip-group)
                (skip-chars-forward " \t")
                (when (eq (char-after) ?{)
                  (beamer-gui--skip-group)
                  (add (list :kind "flow" :name macro :beg start :end (point)
                             :inline t)))))
             ((member env beamer-gui-container-environments))
             ((member env beamer-gui-ignored-environments)
              (beamer-gui--env-end env))
             ((member env '("textblock" "textblock*"))
              (add (list :kind "textblock" :name env :beg start
                         :end (beamer-gui--env-end env))))
             (t
              (add (list :kind "flow" :name env :beg start
                         :end (beamer-gui--env-end env)
                         :inline (and (beamer-gui--inline-name-p env) t))))))))
      (nreverse elements))))

(defun beamer-gui-frame-model (beg end &optional blocks-only)
  "Return the elements of the frame from BEG to END.
The value is a plist: :blocks, those written by beamer-gui, and
:elements, the movable elements of the text, unless BLOCKS-ONLY."
  (let ((blocks (beamer-gui-parse-blocks beg end)))
    (list :blocks blocks
          :elements (unless blocks-only
                      (let ((body (beamer-gui--frame-body beg end)))
                        (beamer-gui-scan-elements (car body) (cdr body) blocks))))))


;;;; Editing lengths and options in the user's own code

(defun beamer-gui--split-options (string)
  "Split the key=value list STRING at top-level commas."
  (let ((depth 0) (start 0) (i 0) parts)
    (while (< i (length string))
      (pcase (aref string i)
        ((or ?{ ?\[) (cl-incf depth))
        ((or ?} ?\]) (cl-decf depth))
        (?, (when (zerop depth)
              (push (substring string start i) parts)
              (setq start (1+ i)))))
      (cl-incf i))
    (push (substring string start) parts)
    (cl-remove-if #'string-empty-p (mapcar #'string-trim (nreverse parts)))))

(defun beamer-gui--parse-length (value)
  "Return (NUMBER . UNIT) for the TeX length VALUE, or nil.
UNIT is a unit name or a length macro; NUMBER defaults to 1."
  (when (string-match (concat "\\`[ \t]*\\(" beamer-gui--number "\\)?[ \t]*"
                              "\\([a-z][a-z]\\|\\\\[a-zA-Z@]+\\)[ \t]*\\'")
                      value)
    (cons (if (match-beginning 1) (float (string-to-number (match-string 1 value))) 1.0)
          (match-string 2 value))))

(defun beamer-gui--scale-length (value factor)
  "Return the TeX length VALUE multiplied by FACTOR, in the same unit."
  (pcase (beamer-gui--parse-length value)
    (`(,number . ,unit) (concat (beamer-gui--fmt (* number factor)) unit))
    (_ (format "%s\\dimexpr %s\\relax" (beamer-gui--fmt factor) value))))

(defun beamer-gui--shift-length (value delta units)
  "Return the TeX length VALUE increased by DELTA points.
UNITS maps unit names and length macros to their size in points.
Return nil if the unit of VALUE is unknown."
  (pcase (beamer-gui--parse-length value)
    (`(,number . ,unit)
     (let ((size (or (cdr (assoc unit units))
                     (cdr (assoc unit beamer-gui--length-units)))))
       (when (and size (> size 0))
         (concat (beamer-gui--fmt (+ number (/ (float delta) size))) unit))))))

(defun beamer-gui--scale-options (options factor default)
  "Scale the size keys of the key=value list OPTIONS by FACTOR.
width and height are scaled, else scale; if none is present, the
option DEFAULT is added first.  Return the new list as a string."
  (let* ((parts (beamer-gui--split-options options))
         (sized nil)
         (new (mapcar
               (lambda (part)
                 (if (string-match "\\`\\(width\\|height\\|scale\\)[ \t]*=[ \t]*\\(.*\\)\\'" part)
                     (let ((key (match-string 1 part)) (value (match-string 2 part)))
                       (setq sized t)
                       (concat key "="
                               (if (equal key "scale")
                                   (beamer-gui--fmt (* factor (string-to-number value)))
                                 (beamer-gui--scale-length value factor))))
                   part))
               parts)))
    (string-join (if sized new (cons default new)) ", ")))

(defun beamer-gui-resize-code (code name factor width)
  "Return CODE of element NAME resized by FACTOR, or nil if not resizable.
An \\includegraphics (or another of `beamer-gui-movable-macros')
gets its size options scaled; a tcolorbox its width option; a
minipage its width.  WIDTH, a fraction of the page width, is the new
width, used when the code has no size option."
  (with-temp-buffer
    (insert code)
    (goto-char (point-min))
    (cond
     ((member name beamer-gui-movable-macros)
      (re-search-forward (concat "\\\\" (regexp-quote name) "\\*?"))
      (beamer-gui--skip-overlay)
      (if (eq (char-after) ?\[)
          (let ((open (point)))
            (beamer-gui--skip-group)
            (let ((options (buffer-substring (1+ open) (1- (point)))))
              (delete-region open (point))
              (insert "[" (beamer-gui--scale-options
                           options factor
                           (format "width=%s\\paperwidth" (beamer-gui--fmt width)))
                      "]")))
        (insert (format "[width=%s\\paperwidth]" (beamer-gui--fmt width))))
      (buffer-string))
     ((equal name "tcolorbox")
      (re-search-forward "\\\\begin{tcolorbox}")
      (if (eq (char-after) ?\[)
          (let ((open (point)))
            (beamer-gui--skip-group)
            (let ((options (buffer-substring (1+ open) (1- (point)))))
              (delete-region open (point))
              (insert "[" (beamer-gui--scale-options
                           options factor
                           (format "width=%s\\linewidth" (beamer-gui--fmt factor)))
                      "]")))
        (insert (format "[width=%s\\linewidth]" (beamer-gui--fmt factor))))
      (buffer-string))
     ((equal name "minipage")
      (re-search-forward "\\\\begin{minipage}")
      (while (progn (skip-chars-forward " \t") (eq (char-after) ?\[))
        (beamer-gui--skip-group))
      (let ((open (point)))
        (beamer-gui--skip-group)
        (let ((value (buffer-substring (1+ open) (1- (point)))))
          (delete-region open (point))
          (insert "{" (beamer-gui--scale-length value factor) "}")))
      (buffer-string)))))

(defun beamer-gui-edit-textblock-head (head dx dy factor units)
  "Return the textblock line HEAD moved by DX, DY points, width times FACTOR.
UNITS maps length units to points, including the textpos modules
\\TPHorizModule and \\TPVertModule used by textblock.  Values keep
their units.  Return nil if a unit is unknown."
  (when (string-match beamer-gui--textblock-head-regexp head)
    (let* ((spans (mapcar (lambda (g) (cons (match-beginning g) (match-end g))) '(2 3 4)))
           (star (equal (match-string 1 head) "textblock*"))
           (hm (cdr (assoc "\\TPHorizModule" units)))
           (vm (cdr (assoc "\\TPVertModule" units)))
           (w (match-string 2 head)) (x (match-string 3 head)) (y (match-string 4 head))
           (new-w (if star (beamer-gui--scale-length w factor)
                    (beamer-gui--fmt (* factor (string-to-number w)))))
           (new-x (if star (beamer-gui--shift-length x dx units)
                    (beamer-gui--fmt (+ (string-to-number x) (/ (float dx) hm)))))
           (new-y (if star (beamer-gui--shift-length y dy units)
                    (beamer-gui--fmt (+ (string-to-number y) (/ (float dy) vm))))))
      (when (and new-x new-y)
        (let ((result head))
          ;; Replace from the end, so earlier positions stay valid.
          (cl-loop for span in (reverse spans)
                   for value in (list new-y new-x new-w)
                   do (setq result (concat (substring result 0 (car span)) value
                                           (substring result (cdr span)))))
          result)))))


;;;; Single-frame documents

(defun beamer-gui-image-dir ()
  "Return the absolute image directory for the current buffer."
  (expand-file-name beamer-gui-image-dir-name
                    (file-name-directory (or buffer-file-name default-directory))))

(defun beamer-gui-graphics-path ()
  "Return the directories of every \\graphicspath in the buffer."
  (save-excursion
    (goto-char (point-min))
    (let (dirs)
      (while (re-search-forward "^[ \t]*\\\\graphicspath{\\(\\(?:{[^}]*}\\)+\\)}" nil t)
        (let ((spec (match-string 1)) (start 0))
          (while (string-match "{\\([^}]*\\)}" spec start)
            (push (match-string 1 spec) dirs)
            (setq start (match-end 0)))))
      (nreverse dirs))))

(defun beamer-gui-strip-notes (doc)
  "Return DOC with beamer note options commented out.
A frame then compiles to slide-sized pages."
  (replace-regexp-in-string
   beamer-gui--notes-regexp
   (lambda (match) (concat "% [beamer-gui] " (string-trim match)))
   doc t t))

(defun beamer-gui--body-setup (&optional from)
  "Return setup commands between \\begin{document} and the first frame.
Search from FROM, default the start of the buffer.  See
`beamer-gui-body-setup-regexp'.  Arguments may span lines."
  (save-excursion
    (goto-char (or from (point-min)))
    (when (re-search-forward beamer-gui--document-begin-regexp nil t)
      (let ((limit (save-excursion
                     (or (re-search-forward beamer-gui--frame-begin-regexp nil t)
                         (point-max))))
            commands)
        (while (re-search-forward beamer-gui-body-setup-regexp limit t)
          (let ((start (line-beginning-position)))
            (goto-char (1- (match-end 0)))
            (beamer-gui--skip-group)
            (push (buffer-substring-no-properties start (line-end-position))
                  commands)))
        (string-join (nreverse commands) "\n")))))

(defun beamer-gui--frame-parts (beg)
  "Return (PREAMBLE SETUP FRAME) for the frame at BEG.
PREAMBLE ends before \\begin{document}; SETUP is the commands kept
from the document body; FRAME is the frame text.  In Org buffers
they come from the beamer export of the subtree at BEG."
  (if (beamer-gui--org-p)
      (let ((doc (progn (require 'ox-beamer)
                        (save-excursion (goto-char beg)
                                        (org-export-as 'beamer t nil nil)))))
        (with-temp-buffer
          (insert doc)
          (goto-char (point-min))
          (re-search-forward beamer-gui--document-begin-regexp)
          (let* ((preamble (buffer-substring (point-min) (line-beginning-position)))
                 (setup (beamer-gui--body-setup))
                 (frame-beg (progn (re-search-forward beamer-gui--frame-begin-regexp)
                                   (line-beginning-position)))
                 (frame-end (progn (goto-char frame-beg)
                                   (re-search-forward "\\\\begin{frame}")
                                   (beamer-gui--env-end "frame"))))
            (list preamble setup (buffer-substring frame-beg frame-end)))))
    (save-excursion
      (let ((frame (beamer-gui-frame-bounds beg)))
        (goto-char (point-min))
        (re-search-forward beamer-gui--document-begin-regexp)
        (list (buffer-substring-no-properties (point-min) (line-beginning-position))
              (or (beamer-gui--body-setup) "")
              (buffer-substring-no-properties (car frame) (cdr frame)))))))

(defun beamer-gui--inner-region (block)
  "Return (BEG . END) of the content of the textblock in BLOCK.
BEG follows the textblock line, END starts the \\end{textblock} line."
  (save-excursion
    (goto-char (plist-get block :beg))
    (re-search-forward "\\\\begin{textblock")
    (forward-line 1)
    (cons (point)
          (progn (goto-char (plist-get block :end))
                 (re-search-backward "^[ \t]*\\\\end{textblock\\*?}")
                 (point)))))

(defun beamer-gui--measure-insertions (model)
  "Return (POSITION . TEXT) insertions measuring the elements of MODEL."
  (let (insertions)
    (cl-flet ((vertical (id beg end)
                (push (cons beg (format "\\bgmarkv{%s}{b}" id)) insertions)
                (push (cons end (format "\\bgmarkv{%s}{e}" id)) insertions))
              (inline (id beg end)
                (push (cons beg (format "\\begin{bgmeasure}{%s}" id)) insertions)
                (push (cons end "\\end{bgmeasure}") insertions)))
      (dolist (e (plist-get model :elements))
        (let ((id (plist-get e :id)))
          (pcase (plist-get e :kind)
            ("textblock" (let ((r (beamer-gui--inner-region e)))
                           (vertical id (car r) (cdr r))))
            (_ (if (plist-get e :inline)
                   (inline id (plist-get e :beg) (plist-get e :end))
                 (vertical id (plist-get e :beg) (plist-get e :end)))))))
      (dolist (b (plist-get model :blocks))
        (let ((id (plist-get b :id)))
          (pcase (plist-get b :kind)
            ((or "text" "raw" "textblock")
             (let ((r (beamer-gui--inner-region b)))
               (vertical id (car r) (cdr r))))
            ("wrap"
             (if (plist-get b :inline)
                 (inline id (plist-get b :code-beg) (plist-get b :code-end))
               (vertical id (plist-get b :code-beg) (plist-get b :code-end))))))))
    insertions))

(defun beamer-gui--background-edits (model)
  "Return (BEG END TEXT) replacements hiding the elements of MODEL.
Flow elements become invisible but keep their space; blocks are
removed, except the spacers of moved elements."
  (let (edits)
    (dolist (e (plist-get model :elements))
      (let ((beg (plist-get e :beg)) (end (plist-get e :end)))
        (push (list beg end
                    (if (equal (plist-get e :kind) "textblock")
                        ""
                      (concat "\\begin{invisibleenv}"
                              (buffer-substring-no-properties beg end)
                              "\\end{invisibleenv}")))
              edits)))
    (dolist (b (plist-get model :blocks))
      ;; A moved element keeps its spacer (and harmless comments).
      (push (if (equal (plist-get b :kind) "wrap")
                (list (plist-get b :head-beg) (plist-get b :wrapper-end) "")
              (list (plist-get b :beg) (plist-get b :end) ""))
            edits))
    edits))

(defun beamer-gui--apply-to-string (text model function)
  "Return TEXT changed by the edits FUNCTION computes from MODEL.
TEXT is visited in a temporary buffer, where MODEL's positions
hold; FUNCTION returns insertions (POS . STRING) or replacements
\(BEG END STRING)."
  (with-temp-buffer
    (insert text)
    (let ((edits (funcall function model)))
      (dolist (edit (sort edits (lambda (a b) (> (car a) (car b)))))
        (goto-char (car edit))
        (if (stringp (cdr edit))
            (insert (cdr edit))
          (delete-region (nth 0 edit) (nth 1 edit))
          (insert (nth 2 edit)))))
    (buffer-string)))

(defun beamer-gui-measure-document (preamble setup frame colors &optional blocks-only)
  "Return the document compiled to edit FRAME.
PREAMBLE and SETUP come from the source document.  The document
has the frame twice: first with markers recording the position of
each element, then with the elements hidden, as the background;
then a page of COLORS swatches.  With BLOCKS-ONLY, the text of the
frame is not scanned for movable elements."
  (with-temp-buffer
    (insert frame)
    (let* ((model (beamer-gui-frame-model (point-min) (point-max) blocks-only))
           (body-end (cdr (beamer-gui--frame-body (point-min) (point-max))))
           (with-end (lambda (mark fn)
                       (lambda (m) (cons (cons body-end (format "\\bgmarkv{%s}{end}\n" mark))
                                         (funcall fn m)))))
           (measured (beamer-gui--apply-to-string
                      frame model (funcall with-end "@A" #'beamer-gui--measure-insertions)))
           (background (beamer-gui--apply-to-string
                        frame model
                        (lambda (m) (cons (list body-end body-end "\\bgmarkv{@B}{end}\n")
                                          (beamer-gui--background-edits m))))))
      (concat (beamer-gui-strip-notes preamble)
              beamer-gui--measure-preamble
              "\\begin{document}\n"
              (if (string-empty-p setup) "" (concat setup "\n"))
              measured "\n"
              "\\addtocounter{framenumber}{-1}\n"
              background "\n"
              (if colors
                  (concat "\\begin{frame}[plain,noframenumbering]\n\\bgmarkv{@S}{start}\n"
                          (mapconcat (lambda (c) (format "\\bgswatch{%s}" c)) colors "\n")
                          "\n\\end{frame}\n")
                "")
              "\\end{document}\n"))))


;;;; Colours

(defun beamer-gui--preamble-sources (text dir &optional depth)
  "Return TEXT followed by the files it \\input or \\include, recursively.
File names are relative to DIR.  DEPTH limits the recursion."
  (let ((depth (or depth 0)) (sources (list text)))
    (when (< depth 5)
      (let ((start 0))
        (while (string-match "\\\\\\(?:input\\|include\\|InputIfFileExists\\){\\([^}]+\\)}"
                             text start)
          (setq start (match-end 0))
          (let* ((name (expand-file-name (match-string 1 text) dir))
                 (file (cl-find-if #'file-regular-p (list name (concat name ".tex")))))
            (when file
              (setq sources
                    (append sources
                            (beamer-gui--preamble-sources
                             (with-temp-buffer (insert-file-contents file) (buffer-string))
                             (file-name-directory file) (1+ depth)))))))))
    sources))

(defun beamer-gui-document-colors (preamble dir)
  "Return the colour names usable in a document with PREAMBLE.
First those the preamble and the files it inputs (relative to DIR)
define, then the dvipsnames colours if that option appears, then
the base xcolor colours; without duplicates."
  (let* ((sources (beamer-gui--preamble-sources preamble dir))
         (defined nil))
    (dolist (text sources)
      (let ((start 0))
        (while (string-match
                (concat "^[^%\n]*?\\\\\\(definecolor\\|providecolor\\|colorlet\\|definecolors\\)"
                        "\\(?:\\[[^]]*\\]\\)?{\\([^}]+\\)}")
                text start)
          (setq start (match-end 0))
          (dolist (name (split-string (match-string 2 text) "," t "[ \t]+"))
            (push name defined)))))
    (delete-dups
     (append (nreverse defined)
             (when (cl-some (lambda (text) (string-match-p "dvipsnames" text)) sources)
               beamer-gui--dvipsnames)
             beamer-gui--base-colors))))


;;;; Measurements

(defun beamer-gui--read-positions (file)
  "Return the positions recorded in FILE, as a list of plists.
Lengths are in points; :x and :y are from the bottom left corner."
  (with-temp-buffer
    (insert-file-contents file)
    (let (marks)
      (dolist (line (split-string (buffer-string) "\n" t))
        (let* ((fields (split-string line " " t))
               (mark (list :id (nth 0 fields) :tag (nth 1 fields))))
          (dolist (field (nthcdr 2 fields))
            (when (string-match "\\`\\([a-z]+\\)=\\(.*\\)\\'" field)
              (let ((key (intern (concat ":" (match-string 1 field))))
                    (value (match-string 2 field)))
                (setq mark (plist-put
                            mark key
                            (cond ((memq key '(:x :y)) (/ (string-to-number value) 65536.0))
                                  ((eq key :page) (string-to-number value))
                                  (t (string-to-number value))))))))
          (push mark marks)))
      (nreverse marks))))

(defun beamer-gui-measurements (file)
  "Return the measurements of FILE as a plist.
:paper (WIDTH HEIGHT) in points, :page-a and :page-b, the last
pages of the measured and background frames (0-based), :frame the
width marks of the frame, :boxes a hash table from element id to a
plist of its marks, and :colors the swatch positions."
  (let* ((marks (beamer-gui--read-positions file))
         (paper (cl-find "@paper" marks :key (lambda (m) (plist-get m :id)) :test #'equal))
         (last-page (lambda (id)
                      (cl-loop for m in marks
                               when (equal (plist-get m :id) id)
                               maximize (plist-get m :page))))
         (page-a (funcall last-page "@A"))
         (page-b (funcall last-page "@B"))
         (boxes (make-hash-table :test #'equal))
         colors)
    (dolist (m marks)
      (let ((id (plist-get m :id)))
        (cond
         ((string-prefix-p "color:" id)
          (push (cons (substring id 6) m) colors))
         ((and (eql (plist-get m :page) page-a) (not (string-prefix-p "@" id)))
          (puthash id (plist-put (gethash id boxes) (intern (concat ":" (plist-get m :tag))) m)
                   boxes)))))
    (list :paper (list (plist-get paper :pw) (plist-get paper :ph))
          :page-a (and page-a (1- page-a)) :page-b (and page-b (1- page-b))
          :page-s (cl-loop for (_ . m) in colors maximize (1- (plist-get m :page)))
          :frame (cl-find-if (lambda (m) (and (equal (plist-get m :id) "@A")
                                              (eql (plist-get m :page) page-a)))
                             marks)
          :boxes boxes
          :colors (nreverse colors))))

(defun beamer-gui-element-box (recorded paper)
  "Return the box of an element from its RECORDED positions.
RECORDED is the plist :b and :e of a vertical element, or :i of an
inline one.  PAPER is (WIDTH HEIGHT) in points.  The value is a
plist :box (X Y W H) from the top left, and the lengths in points
needed for a spacer: :height :depth :width."
  (pcase-let ((`(,pw ,ph) paper))
    (if-let ((i (plist-get recorded :i)))
        (let ((x (plist-get i :x)) (y (plist-get i :y))
              (wd (plist-get i :wd)) (ht (plist-get i :ht)) (dp (plist-get i :dp)))
          (list :box (list (/ x pw) (/ (- ph (+ y ht)) ph) (/ wd pw) (/ (+ ht dp) ph))
                :inline t :width wd :height ht :depth dp
                :lw (plist-get i :lw) :tw (plist-get i :tw)))
      ;; The mark before the element precedes the skip ending the
      ;; previous paragraph (:ls), which stays in place when the element
      ;; moves; the mark after it precedes its own last skip, which the
      ;; spacer restores so that the next \\addvspace sees it.
      (let* ((b (plist-get recorded :b)) (e (plist-get recorded :e))
             (top (- (plist-get b :y) (or (plist-get b :ls) 0)))
             (bottom (plist-get e :y))
             (pd (max 0 (or (plist-get e :pd) 0))))
        (list :box (list (/ (plist-get b :x) pw) (/ (- ph top) ph)
                         (/ (plist-get b :lw) pw) (/ (- top bottom (- pd)) ph))
              :height (- top bottom) :depth (or (plist-get e :pd) 0)
              :skip (or (plist-get e :ls) 0)
              :before-skip (or (plist-get b :ls) 0)
              :before-depth (or (plist-get b :pd) -1000)
              :lw (plist-get b :lw) :tw (plist-get b :tw)
              :hm (plist-get b :hm) :vm (plist-get b :vm))))))


;;;; Frames

(defun beamer-gui-frame-bounds (&optional pos)
  "Return (BEG . END) of the frame around POS, or nil if none.
POS defaults to point.  In Org buffers the frame is the current subtree."
  (setq pos (or pos (point)))
  (save-excursion
    (goto-char pos)
    (if (beamer-gui--org-p)
        (progn
          (org-back-to-heading t)
          (cons (point) (progn (org-end-of-subtree t t) (point))))
      (end-of-line)
      (when (re-search-backward beamer-gui--frame-begin-regexp nil t)
        (let ((beg (point)))
          (re-search-forward "\\\\begin{frame}")
          (when (and (ignore-errors (beamer-gui--env-end "frame"))
                     (>= (point) pos))
            (cons beg (point))))))))

(defun beamer-gui-frame-ordinal (beg)
  "Return the 1-based index of the frame starting at BEG."
  (save-excursion
    (goto-char (point-min))
    (let ((regexp (if (beamer-gui--org-p)
                      beamer-gui--org-heading-regexp
                    beamer-gui--frame-begin-regexp))
          (n 0))
      (while (and (re-search-forward regexp nil t) (<= (match-beginning 0) beg))
        (cl-incf n))
      n)))

(defun beamer-gui--insertion-point (beg end)
  "Return where new blocks go in the frame from BEG to END."
  (save-excursion
    (goto-char end)
    (if (beamer-gui--org-p)
        (progn (skip-chars-backward " \t\n")
               (forward-line 1))
      (search-backward "\\end{frame}" beg)
      (forward-line 0))
    (point)))


;;;; Elements as the GUI sees them

(defun beamer-gui--resize-mode (name inline)
  "Return how the GUI may resize element NAME, INLINE or not.
\"aspect\" keeps the aspect ratio, \"width\" changes the width only,
\"none\" forbids resizing."
  (cond ((member name beamer-gui-movable-macros) "aspect")
        ((member name '("tcolorbox" "minipage")) "width")
        (inline "none")
        (t "width")))

(defun beamer-gui--measured (id measurements)
  "Return the element box of ID from MEASUREMENTS, or nil."
  (let ((marks (gethash id (plist-get measurements :boxes))))
    (when (or (plist-get marks :i)
              (and (plist-get marks :b) (plist-get marks :e)))
      (beamer-gui-element-box marks (plist-get measurements :paper)))))

(defun beamer-gui-gui-items (model measurements)
  "Return the elements of MODEL for the GUI, with their MEASUREMENTS.
Elements of the text that were not measured (not on the last slide
of the frame) are left out."
  (let (items)
    (dolist (b (plist-get model :blocks))
      (let ((id (plist-get b :id))
            (box (plist-get (beamer-gui--measured (plist-get b :id) measurements) :box)))
        (pcase (plist-get b :kind)
          ((or "image" "arrow" "ellipse" "rect")
           (push (cl-loop for (k v) on (beamer-gui--item-data b) by #'cddr
                          unless (eq k :legacy) append (list k v))
                 items))
          ((or "text" "raw")
           (push (append (beamer-gui--item-data b)
                         (and box (list :box (vconcat box))))
                 items))
          ("wrap"
           (when box
             (push (list :kind "wrap" :id id :name (plist-get b :moved)
                         :box (vconcat box)
                         :resize (beamer-gui--resize-mode (plist-get b :moved)
                                                          (plist-get b :inline)))
                   items)))
          ("textblock"
           (when box
             (push (list :kind "textblock" :id id :name (plist-get b :name)
                         :box (vconcat box) :resize "width")
                   items))))))
    (dolist (e (plist-get model :elements))
      (when-let ((box (plist-get (beamer-gui--measured (plist-get e :id) measurements) :box)))
        (push (list :kind (plist-get e :kind) :id (plist-get e :id)
                    :name (plist-get e :name) :box (vconcat box)
                    :resize (if (equal (plist-get e :kind) "textblock") "width"
                              (beamer-gui--resize-mode (plist-get e :name)
                                                       (plist-get e :inline))))
              items)))
    (nreverse items)))


;;;; Writing the changes made in the GUI

(defun beamer-gui--same-p (a b)
  "Return non-nil if element data A and B agree, numbers to 1e-4."
  (cl-loop for (key value) on (beamer-gui--item-data a) by #'cddr
           always (let ((other (plist-get b key)))
                    (or (memq key '(:legacy :box))
                        (if (and (numberp value) (numberp other))
                            (< (abs (- value other)) 1e-4)
                          (equal (or value "") (or other "")))))))

(defun beamer-gui--box-change (item)
  "Return (DX DY FACTOR) of ITEM's :box from its :box0, or nil if unchanged.
DX and DY are page fractions, FACTOR the change of width."
  (let ((box (append (plist-get item :box) nil))
        (box0 (append (plist-get item :box0) nil)))
    (when (and box box0
               (cl-some (lambda (a b) (> (abs (- a b)) 1e-4)) box box0))
      (list (- (nth 0 box) (nth 0 box0)) (- (nth 1 box) (nth 1 box0))
            (/ (nth 2 box) (max (nth 2 box0) 1e-6))))))

(defun beamer-gui--used-ids ()
  "Return the identifiers of all beamer-gui blocks in the buffer."
  (save-excursion
    (goto-char (point-min))
    (let (ids)
      (while (re-search-forward (concat beamer-gui--header-regexp "\\|"
                                        "% *gui:\\(" beamer-gui--id-regexp "\\)")
                                nil t)
        (push (or (match-string 1) (match-string 3)) ids))
      ids)))

(defun beamer-gui--new-id (prefix used)
  "Return PREFIX followed by the first number not giving an id in USED.
The new id is added to USED, a list held in a cons cell (LIST)."
  (let ((n 1))
    (while (member (format "%s%d" prefix n) (car used)) (cl-incf n))
    (push (format "%s%d" prefix n) (car used))
    (format "%s%d" prefix n)))

(defun beamer-gui--line-start (pos)
  "Return the start of the line of POS."
  (save-excursion (goto-char pos) (line-beginning-position)))

(defun beamer-gui--replace-framed (beg end id extra body-function)
  "Return (START END TEXT) replacing BEG..END by a block ID.
BODY-FUNCTION is called with the indentation of BEG and returns
the body; EXTRA is added to the first comment line.  If only blanks
precede BEG on its line, the block starts at the line start with
that indentation.  Line breaks are added only where BEG..END does
not already start or end a line, with a % so that they add no
space."
  (let* ((line-start (beamer-gui--line-start beg))
         (blank (save-excursion (goto-char beg)
                                (looking-back "^[ \t]*" line-start)))
         (start (if blank line-start beg))
         (indent (if blank (buffer-substring-no-properties line-start beg) "")))
    (list start end
          (concat (if blank "" "%\n")
                  (beamer-gui--framed id extra (funcall body-function indent) indent)
                  (save-excursion (goto-char end) (if (eolp) "" "\n"))))))

(defun beamer-gui--indent-code (code indent)
  "Return CODE one level deeper than INDENT.
Its first line had no indentation; the others keep theirs."
  (concat indent "  "
          (replace-regexp-in-string "\n" "\n  " code t t)))

(defun beamer-gui--restore-lines (code width box-pt inline)
  "Return lines restoring \\linewidth and \\textwidth inside a wrapper.
CODE is the wrapped code, WIDTH the wrapper width in points, INLINE
non-nil for an element set in a line, BOX-PT
the measured element.  Inside a textblock both lengths are the
block width; they are set back to their outside values when CODE
uses them and they differ."
  (let ((pw (plist-get box-pt :pw)) lines)
    (dolist (spec (list (list "\\linewidth" (plist-get box-pt :lw) inline)
                        (list "\\textwidth" (plist-get box-pt :tw) t)))
      (pcase-let ((`(,macro ,value ,wanted) spec))
        (when (and wanted value
                   (string-match-p (regexp-quote macro) code)
                   (> (abs (- value width)) 0.5))
          (push (format "\\setlength{%s}{%s\\paperwidth}%% as outside the block"
                        macro (beamer-gui--fmt (/ value pw)))
                lines))))
    (mapconcat (lambda (l) (concat l "\n")) (nreverse lines) "")))

(defun beamer-gui--wrap-edit (element item box-pt used)
  "Return the edit wrapping flow ELEMENT as ITEM placed it.
BOX-PT is the element's measurement; USED holds the used ids."
  (pcase-let* ((`(,x ,y ,w ,_h) (append (plist-get item :box) nil))
               (pw (plist-get box-pt :pw))
               (name (plist-get element :name))
               (inline (plist-get element :inline))
               (`(,_dx ,_dy ,factor) (beamer-gui--box-change item))
               (code (buffer-substring-no-properties (plist-get element :beg)
                                                     (plist-get element :end)))
               (code (or (and factor (> (abs (- factor 1)) 1e-3)
                              (beamer-gui-resize-code code name factor w))
                         code))
               (id (beamer-gui--new-id "w" used))
               (spacer (if inline
                           (format "\\beamerguihspace{%s}{%s}{%s}%%"
                                   (beamer-gui--pt (plist-get box-pt :width))
                                   (beamer-gui--pt (plist-get box-pt :height))
                                   (beamer-gui--pt (plist-get box-pt :depth)))
                         (format "\\beamerguivspace{%s}{%s}{%s}"
                                 (beamer-gui--pt (plist-get box-pt :height))
                                 (beamer-gui--pt (plist-get box-pt :depth))
                                 (beamer-gui--pt (plist-get box-pt :skip)))))
               (restore (concat
                         (unless inline
                           (format "\\beamerguicontext{%s}{%s}%% as in the text\n"
                                   (beamer-gui--pt (plist-get box-pt :before-skip))
                                   (beamer-gui--pt (plist-get box-pt :before-depth))))
                         (beamer-gui--restore-lines code (* w pw) box-pt inline)))
               (y (- y (/ (or (plist-get box-pt :before-skip) 0) (plist-get box-pt :ph)))))
    (beamer-gui--replace-framed
     (plist-get element :beg) (plist-get element :end) id (format "(moved %s)" name)
     (lambda (indent)
       ;; An inline element's spacer comes first: it then starts the
       ;; paragraph as the element did (in a list, \\item applies to it).
       (let ((wrapper (concat indent (beamer-gui--wrapper x y w) "\n"
                              (mapconcat (lambda (line) (concat indent "  " line "\n"))
                                         (split-string restore "\n" t) "")
                              (beamer-gui--indent-code code indent) "\n"
                              indent "\\end{textblock*}\n")))
         (if inline
             (concat indent spacer "\n" wrapper)
           (concat wrapper indent spacer)))))))

(defun beamer-gui--rewrap-edits (block item before-skip)
  "Return the edits that move or resize the moved element BLOCK like ITEM.
BEFORE-SKIP, a page fraction, separates the wrapper top from the
element's box, as measured."
  (pcase-let* ((`(,x ,y ,w ,_h) (append (plist-get item :box) nil))
               (y (- y before-skip))
               (`(,_dx ,_dy ,factor) (beamer-gui--box-change item))
               (name (plist-get block :moved))
               (indent (save-excursion (goto-char (plist-get block :head-beg))
                                       (buffer-substring-no-properties
                                        (point) (progn (skip-chars-forward " \t") (point)))))
               (edits (list (list (plist-get block :head-beg) (plist-get block :head-end)
                                  (concat indent (beamer-gui--wrapper x y w) "\n")))))
    (when (and factor (> (abs (- factor 1)) 1e-3))
      (let* ((code (buffer-substring-no-properties (plist-get block :code-beg)
                                                   (plist-get block :code-end)))
             (new (beamer-gui-resize-code (string-trim-right code) name factor w)))
        (when new
          (push (list (plist-get block :code-beg) (plist-get block :code-end)
                      (concat new "\n"))
                edits))))
    edits))

(defun beamer-gui--textblock-edits (beg end item units used framed)
  "Return the edits moving or resizing the textblock from BEG to END.
ITEM gives the new box, UNITS the length units in points.  Unless
FRAMED, the block gets the comment lines, with a new id from USED."
  (pcase-let* ((`(,dx ,dy ,factor) (beamer-gui--box-change item))
               (pw (cdr (assoc "\\paperwidth" units)))
               (ph (cdr (assoc "\\paperheight" units)))
               (start (save-excursion (goto-char beg) (skip-chars-forward " \t\n") (point)))
               (head-end (save-excursion (goto-char start)
                                         (when (looking-at beamer-gui--textblock-head-regexp)
                                           (match-end 0))))
               (head (and head-end (buffer-substring-no-properties start head-end)))
               (new (and head (beamer-gui-edit-textblock-head
                               head (* dx pw) (* dy ph) factor units))))
    (cond
     ((not new)
      (message "beamer-gui: cannot convert the units of %s" (or head "a textblock"))
      nil)
     (framed (list (list start head-end new)))
     (t
      (list (beamer-gui--replace-framed
             start end (beamer-gui--new-id "tb" used) "(textblock)"
             (lambda (indent)
               (concat indent new (buffer-substring-no-properties head-end end)))))))))

(defun beamer-gui-apply-items (beg end items &optional measurements)
  "Make the frame from BEG to END match ITEMS, as returned by the GUI.
Drawn elements (image, arrow, ellipse, rect, text) are added,
rewritten when changed, and deleted when missing from ITEMS.
Moved elements of the text are wrapped; moved textblocks keep their
units.  MEASUREMENTS, from the last compilation, give the sizes of
spacers and the length units.  Unchanged code is left as it is.
The whole edit is a single undo step."
  (let* ((model (beamer-gui-frame-model beg end (beamer-gui--org-p)))
         (blocks (plist-get model :blocks))
         (by-id (lambda (id list) (cl-find id list :key (lambda (x) (plist-get x :id))
                                           :test #'equal)))
         (used (list (append (beamer-gui--used-ids)
                             (mapcar (lambda (i) (plist-get i :id)) items))))
         (paper (plist-get measurements :paper))
         (frame (plist-get measurements :frame))
         (units-for (lambda (id)
                      (let ((marks (plist-get (gethash id (plist-get measurements :boxes)) :b)))
                        (append (list (cons "\\paperwidth" (nth 0 paper))
                                      (cons "\\paperheight" (nth 1 paper))
                                      (cons "\\textwidth" (plist-get frame :tw))
                                      (cons "\\linewidth" (plist-get frame :lw))
                                      (cons "\\TPHorizModule" (plist-get marks :hm))
                                      (cons "\\TPVertModule" (plist-get marks :vm)))))))
         (drawn '("image" "arrow" "ellipse" "rect" "text" "raw"))
         (edits nil) (new nil))
    ;; Drawn elements.
    (dolist (b blocks)
      (when (member (plist-get b :kind) drawn)
        (let ((item (funcall by-id (plist-get b :id) items)))
          (cond
           ((not item)
            (push (list (plist-get b :beg)
                        (save-excursion (goto-char (plist-get b :end))
                                        (if (looking-at "[ \t]*\n") (match-end 0) (point)))
                        "")
                  edits))
           ((not (beamer-gui--same-p item b))
            (push (list (plist-get b :beg) (plist-get b :end)
                        (beamer-gui-item-to-tex item))
                  edits))))))
    (dolist (item items)
      (let ((id (plist-get item :id)) (kind (plist-get item :kind)))
        (cond
         ((member kind drawn)
          (unless (funcall by-id id blocks) (push item new)))
         ((not (beamer-gui--box-change item)))
         ((equal kind "flow")
          (when-let ((element (funcall by-id id (plist-get model :elements)))
                     (box-pt (beamer-gui--measured id measurements)))
            (push (beamer-gui--wrap-edit
                   element item
                   (append (list :pw (nth 0 paper) :ph (nth 1 paper)) box-pt) used)
                  edits)))
         ((equal kind "wrap")
          (when-let ((block (funcall by-id id blocks)))
            (let ((box-pt (beamer-gui--measured id measurements)))
              (setq edits (append (beamer-gui--rewrap-edits
                                   block item
                                   (/ (or (plist-get box-pt :before-skip) 0) (nth 1 paper)))
                                  edits)))))
         ((equal kind "textblock")
          (let ((element (funcall by-id id (plist-get model :elements)))
                (block (funcall by-id id blocks)))
            (setq edits
                  (append
                   (cond
                    (element (beamer-gui--textblock-edits
                              (plist-get element :beg) (plist-get element :end)
                              item (funcall units-for id) used nil))
                    (block (let ((r (cons (plist-get block :inner-beg)
                                          (plist-get block :inner-end))))
                             (beamer-gui--textblock-edits
                              (car r) (cdr r) item (funcall units-for id) used t))))
                   edits)))))))
    (when new
      (let ((at (beamer-gui--insertion-point beg end)))
        (push (list at at (mapconcat (lambda (i) (concat (beamer-gui-item-to-tex i) "\n"))
                                     (nreverse new) ""))
              edits)))
    (beamer-gui--apply-edits edits)))

(defun beamer-gui--apply-edits (edits)
  "Apply EDITS, a list of (BEG END TEXT), as one undo step."
  (let ((group (prepare-change-group)))
    (unwind-protect
        (progn
          (activate-change-group group)
          (save-excursion
            (dolist (edit (sort edits (lambda (a b) (> (car a) (car b)))))
              (goto-char (nth 0 edit))
              (delete-region (nth 0 edit) (nth 1 edit))
              (insert (nth 2 edit))))
          (undo-amalgamate-change-group group)
          (accept-change-group group)
          (setq group nil))
      (when group (cancel-change-group group)))))

(defun beamer-gui-unwrap ()
  "Put the moved element at point back into the text flow.
Its wrapper, spacer and comment lines are removed; changes of size
made in the GUI are kept."
  (interactive)
  (let* ((bounds (or (beamer-gui-frame-bounds) (user-error "Not in a frame")))
         (block (cl-find-if (lambda (b) (and (equal (plist-get b :kind) "wrap")
                                             (<= (plist-get b :beg) (point) (plist-get b :end))))
                            (beamer-gui-parse-blocks (car bounds) (cdr bounds)))))
    (unless block (user-error "Point is not in an element moved by beamer-gui"))
    (beamer-gui--apply-edits
     (list (list (plist-get block :beg) (plist-get block :end)
                 ;; The code was indented one level inside the wrapper.
                 (replace-regexp-in-string
                  "^  " ""
                  (string-trim-right
                   (buffer-substring-no-properties (plist-get block :code-beg)
                                                   (plist-get block :code-end)))))))))


;;;; Labels

(defun beamer-gui--slug (title)
  "Return a label-friendly slug of TITLE, at most 30 characters."
  (let* ((s (downcase (replace-regexp-in-string "\\\\[a-zA-Z]+\\|[{}$]" "" title)))
         (s (replace-regexp-in-string "[^a-z0-9]+" "-" s))
         (s (string-trim s "-+" "-+")))
    (substring s 0 (min 30 (length s)))))

(defun beamer-gui--frame-options ()
  "Return (START . END) of the [options] after point, or nil."
  (when (eq (char-after) ?\[)
    (cons (point) (save-excursion (search-forward "]" (line-end-position))))))

(defun beamer-gui--frame-title (from)
  "Return the title of the frame whose header continues at FROM, or nil.
Both \\begin{frame}{Title} and \\frametitle{Title} are recognized."
  (save-excursion
    (goto-char from)
    (cond
     ((looking-at "{\\([^}]*\\)}") (match-string 1))
     ((re-search-forward "\\\\frametitle{\\([^}]*\\)}"
                         (save-excursion
                           (re-search-forward beamer-gui--frame-end-regexp nil t))
                         t)
      (match-string 1)))))

(defun beamer-gui--used-labels ()
  "Return a hash table of the labels set in frame options."
  (let ((used (make-hash-table :test #'equal)))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "label=\\([^],}]+\\)" nil t)
        (puthash (string-trim (match-string 1)) t used)))
    used))

(defun beamer-gui--unique-label (base used)
  "Return fr:BASE, suffixed if needed to be absent from USED, and record it."
  (let ((label (concat "fr:" base)) (k 1))
    (while (gethash label used)
      (setq label (format "fr:%s-%d" base (cl-incf k))))
    (puthash label t used)
    label))

(defun beamer-gui-label-frames ()
  "Add a label to every \\begin{frame} that lacks one.
The label is fr:SLUG with SLUG derived from the frame title, or the
frame number for untitled frames, and is unique in the buffer.
`beamer-gui-edit-frame' does not need labels.  Return the number
of labels added."
  (interactive)
  (let ((used (beamer-gui--used-labels))
        (count 0) (n 0))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward beamer-gui--frame-begin-regexp nil t)
        (cl-incf n)
        (let* ((options (beamer-gui--frame-options))
               (text (and options (buffer-substring (car options) (cdr options)))))
          (unless (and text (string-match-p "label=" text))
            (let* ((slug (beamer-gui--slug
                          (or (beamer-gui--frame-title (if options (cdr options) (point)))
                              "")))
                   (label (beamer-gui--unique-label
                           (if (string-empty-p slug) (number-to-string n) slug)
                           used)))
              (if (not options)
                  (insert "[label=" label "]")
                (goto-char (1- (cdr options)))
                (insert (if (equal text "[]") "" ",") "label=" label))
              (cl-incf count))))))
    (when (called-interactively-p 'interactive)
      (message "beamer-gui: added %d label(s)" count))
    count))

;;;; Preamble

(defun beamer-gui--preamble-version (text)
  "Return the version of the beamer-gui preamble in TEXT, or nil.
Version 1 is the preamble of beamer-gui 0.1."
  (cond ((string-match "^%%% beamer-gui preamble \\([0-9]+\\)" text)
         (string-to-number (match-string 1 text)))
        ((string-match-p "gui arrow/\\.style" text) 1)))

(defun beamer-gui-insert-preamble ()
  "Insert or update `beamer-gui-preamble' before \\begin{document}."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (cond
     ((re-search-forward "^%%% beamer-gui preamble \\([0-9]+\\)" nil t)
      (if (>= (string-to-number (match-string 1)) beamer-gui--preamble-version)
          (message "beamer-gui: preamble already present")
        (let ((beg (match-beginning 0)))
          (re-search-forward beamer-gui--footer-regexp)
          (delete-region beg (1+ (point)))
          (goto-char beg)
          (insert beamer-gui-preamble))))
     ((re-search-forward "^%% beamer-gui$" nil t)
      ;; Version 0.1: from its comment to the line of the ellipse style.
      (let ((beg (match-beginning 0)))
        (re-search-forward "gui ellipse/\\.style.*\n")
        (delete-region beg (point))
        (goto-char beg)
        (insert beamer-gui-preamble)))
     (t
      (re-search-forward beamer-gui--document-begin-regexp)
      (forward-line 0)
      (insert beamer-gui-preamble)))))


;;;; Compilation

(defun beamer-gui--compile (doc dir tmpdir callback &optional on-fail)
  "Compile DOC from directory DIR with output in TMPDIR.
Call CALLBACK with the PDF file name on success.  On failure, call
ON-FAIL with the log file name if non-nil, else report the log."
  (let ((tex (expand-file-name "frame.tex" tmpdir))
        (default-directory dir))
    (with-temp-file tex (insert doc))
    (make-process
     :name "beamer-gui-latex"
     :buffer (get-buffer-create " *beamer-gui-latex*")
     :command (append beamer-gui-latex-command
                      (list (concat "-output-directory=" tmpdir) tex))
     :sentinel
     (lambda (process _event)
       (when (memq (process-status process) '(exit signal))
         (if (zerop (process-exit-status process))
             (funcall callback (expand-file-name "frame.pdf" tmpdir))
           (let ((log (expand-file-name "frame.log" tmpdir)))
             (if on-fail
                 (funcall on-fail log)
               (message "beamer-gui: LaTeX failed, see %s" log)))))))))


;;;; Editing session

(cl-defstruct (beamer-gui--session
               (:constructor beamer-gui--session-create)
               (:copier nil))
  "State of one frame being edited."
  buffer beg end tmpdir process measurements)

(defvar-local beamer-gui--current-session nil
  "The `beamer-gui--session' of this buffer, if any.")

(defun beamer-gui--color-positions (measurements)
  "Return the swatch centres of MEASUREMENTS as plists for the GUI."
  (pcase-let ((`(,pw ,ph) (plist-get measurements :paper))
              (half 4.268))                 ; 1.5mm, half a swatch
    (vconcat
     (mapcar (lambda (c)
               (let ((m (cdr c)))
                 (list :name (car c)
                       :x (/ (+ (plist-get m :x) half) pw)
                       :y (/ (- ph (+ (plist-get m :y) half)) ph))))
             (plist-get measurements :colors)))))

(defun beamer-gui--session-json (session pdf)
  "Return the GUI input of SESSION, whose frame compiled to PDF."
  (with-current-buffer (beamer-gui--session-buffer session)
    (let* ((beg (marker-position (beamer-gui--session-beg session)))
           (end (marker-position (beamer-gui--session-end session)))
           (measurements (beamer-gui--session-measurements session))
           (model (beamer-gui-frame-model beg end (beamer-gui--org-p))))
      (json-serialize
       (list :background pdf
             :paper (vconcat (plist-get measurements :paper))
             :page_a (or (plist-get measurements :page-a) -1)
             :page_b (or (plist-get measurements :page-b) -1)
             :page_s (or (plist-get measurements :page-s) -1)
             :colors (beamer-gui--color-positions measurements)
             :tex_dir (file-name-directory buffer-file-name)
             :image_dir (beamer-gui-image-dir)
             :stem (format "%s-f%d" (file-name-base buffer-file-name)
                           (beamer-gui-frame-ordinal beg))
             :graphics_path (vconcat (beamer-gui-graphics-path))
             :items (vconcat (beamer-gui-gui-items model measurements)))))))

(defun beamer-gui--compile-session (session callback)
  "Compile the frame of SESSION, measure it, write the GUI input.
Call CALLBACK with the name of the GUI input file."
  (with-current-buffer (beamer-gui--session-buffer session)
    (pcase-let* ((beg (marker-position (beamer-gui--session-beg session)))
                 (dir (file-name-directory buffer-file-name))
                 (tmpdir (beamer-gui--session-tmpdir session))
                 (`(,preamble ,setup ,frame) (beamer-gui--frame-parts beg))
                 (version (cl-some #'beamer-gui--preamble-version
                                   (beamer-gui--preamble-sources preamble dir))))
      (unless (eql version beamer-gui--preamble-version)
        (user-error "Run M-x beamer-gui-insert-preamble to %s the beamer-gui preamble"
                    (if version "update" "add")))
      (beamer-gui--compile
       (beamer-gui-measure-document preamble setup frame
                                    (beamer-gui-document-colors preamble dir)
                                    (beamer-gui--org-p))
       dir tmpdir
       (lambda (pdf)
         (setf (beamer-gui--session-measurements session)
               (beamer-gui-measurements (expand-file-name "frame.bgpos" tmpdir)))
         (let ((file (expand-file-name "session.json" tmpdir))
               (json (beamer-gui--session-json session pdf)))
           (with-temp-file file (insert json))
           (funcall callback file)))))))

(defun beamer-gui--send (session message)
  "Send MESSAGE, a plist, to the GUI of SESSION as a JSON line."
  (let ((process (beamer-gui--session-process session)))
    (when (process-live-p process)
      (process-send-string process (concat (json-serialize message) "\n")))))

(defun beamer-gui--save-items (session items)
  "Write ITEMS from the GUI into the frame of SESSION and recompile."
  (with-current-buffer (beamer-gui--session-buffer session)
    (let ((beg (beamer-gui--session-beg session))
          (end (beamer-gui--session-end session)))
      (beamer-gui-apply-items (marker-position beg) (marker-position end) items
                              (beamer-gui--session-measurements session))
      (set-marker end (cdr (beamer-gui-frame-bounds beg)))))
  (beamer-gui--compile-session
   session (lambda (file) (beamer-gui--send session (list :session file)))))

(defun beamer-gui--filter (session)
  "Return a process filter dispatching GUI messages for SESSION."
  (let ((pending ""))
    (lambda (_process output)
      (setq pending (concat pending output))
      (while (string-match "\n" pending)
        (let ((line (substring pending 0 (match-beginning 0))))
          (setq pending (substring pending (match-end 0)))
          (when (string-prefix-p "{" line)
            (let ((items (plist-get (json-parse-string line :object-type 'plist
                                                       :array-type 'list
                                                       :null-object nil)
                                    :items)))
              (when (listp items)
                (beamer-gui--save-items session items)))))))))

(defun beamer-gui--start-gui (session file)
  "Start the GUI process of SESSION on the GUI input FILE."
  (setf (beamer-gui--session-process session)
        (make-process
         :name "beamer-gui"
         :buffer (get-buffer-create " *beamer-gui*")
         :command (list beamer-gui-python beamer-gui-script file)
         :connection-type 'pipe
         :stderr (get-buffer-create "*beamer-gui-errors*")
         :filter (beamer-gui--filter session))))

;;;###autoload
(defun beamer-gui-edit-frame ()
  "Edit the elements of the frame at point in the GUI.
Saving in the GUI rewrites the changed elements in this buffer."
  (interactive)
  (unless buffer-file-name
    (user-error "Buffer must visit a file"))
  (let ((bounds (or (beamer-gui-frame-bounds) (user-error "Not in a frame"))))
    (when-let ((old beamer-gui--current-session))
      (when (process-live-p (beamer-gui--session-process old))
        (delete-process (beamer-gui--session-process old))))
    (let ((session (beamer-gui--session-create
                    :buffer (current-buffer)
                    :beg (copy-marker (car bounds))
                    :end (copy-marker (cdr bounds) t)
                    :tmpdir (make-temp-file "beamer-gui" t))))
      (setq beamer-gui--current-session session)
      (beamer-gui--compile-session
       session (lambda (file) (beamer-gui--start-gui session file)))
      (message "beamer-gui: compiling frame..."))))


;;;; Minor mode

(defvar beamer-gui-mode-map
  (let ((map (make-sparse-keymap)))
    ;; C-c followed by a letter is reserved for users by the GNU key
    ;; binding conventions; C-c M-g is free in Emacs, AUCTeX and RefTeX.
    (define-key map (kbd "C-c M-g") #'beamer-gui-edit-frame)
    map)
  "Keymap of `beamer-gui-mode'.")

;;;###autoload
(define-minor-mode beamer-gui-mode
  "Minor mode giving a key to edit the beamer frame at point.

\\{beamer-gui-mode-map}"
  :lighter " BGui"
  :keymap beamer-gui-mode-map)

(provide 'beamer-gui)
;;; beamer-gui.el ends here
