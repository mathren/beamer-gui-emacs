;;; beamer-gui.el --- Edit textpos elements of beamer frames graphically  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Mathieu Renzo

;; Author: Mathieu Renzo
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tex, tools, multimedia
;; URL: https://github.com/mathren/beamer-gui

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

;; Edit the graphical elements of the beamer frame at point in a Qt
;; window: drag, resize, delete, add arrows and ellipses, paste images.
;;
;; Managed elements are `textblock*' environments of the textpos
;; package tagged with a `% gui:ID' comment, for example:
;;
;;   \begin{textblock*}{0.3\paperwidth}(0.1\paperwidth,0.2\paperheight) % gui:img1
;;     \includegraphics[width=\linewidth]{fig_slides/plot.png}
;;   \end{textblock*}
;;
;; Coordinates are fractions of the page, origin at the top left.
;; Untagged blocks are never modified.  Run `beamer-gui-insert-preamble'
;; once per document.
;;
;; Frames are edited without labels: the frame is compiled alone with
;; the document preamble (in Org, the subtree is exported), with
;; beamer note options turned off so the page is slide-sized.
;; `beamer-gui-label-frames' adds labels if you want them anyway.
;;
;; Pasted images are saved in `beamer-gui-image-dir-name' next to the
;; source file.  The GUI (beamer_gui.py) needs PySide6 and PyMuPDF.
;;
;; Entry point: `beamer-gui-edit-frame', bound to C-c + in
;; `beamer-gui-mode', a minor mode to enable in LaTeX buffers.  Set
;; `beamer-gui-python' to the Python with PySide6 and PyMuPDF.

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


;;;; Constants

(defconst beamer-gui-preamble
  "%% beamer-gui
\\RequirePackage{tikz}
\\makeatletter\\@ifpackageloaded{textpos}{}{\\usepackage[absolute,overlay]{textpos}}\\makeatother
\\tikzset{gui arrow/.style={->,>=stealth,line width=2pt,red},
         gui ellipse/.style={line width=2pt,red}}
"
  "Preamble lines required by managed elements.")

(defconst beamer-gui--preamble-marker "gui arrow/.style"
  "String whose presence means `beamer-gui-preamble' is installed.")

(defconst beamer-gui--document-begin-regexp "^[ \t]*\\\\begin{document}")
(defconst beamer-gui--frame-begin-regexp "^[ \t]*\\\\begin{frame}")
(defconst beamer-gui--frame-end-regexp "\\\\end{frame}")
(defconst beamer-gui--org-heading-regexp "^\\*+ ")

(defconst beamer-gui--notes-regexp
  "^[ \t]*\\\\setbeameroption{[ \t]*show \\(?:only \\)?notes[^}]*}"
  "Regexp for beamer options adding note pages or a second screen.")

(defconst beamer-gui--id-regexp "[[:alnum:]_-]+"
  "Regexp for element identifiers.")

(defconst beamer-gui--number-group "\\(-?[0-9]*\\.?[0-9]+\\)"
  "Regexp group matching a decimal number.")

(defconst beamer-gui--block-regexp
  (let ((n beamer-gui--number-group))
    (concat "\\\\begin{textblock\\*}{" n "\\\\paperwidth}"
            "(" n "\\\\paperwidth," n "\\\\paperheight)"
            "[ \t]*%[ \t]*gui:\\(" beamer-gui--id-regexp "\\)[^\n]*\n"
            "\\(\\(?:.\\|\n\\)*?\\)[ \t]*\\\\end{textblock\\*}"))
  "Regexp for a managed block.
Groups: 1 width, 2 x, 3 y, 4 identifier, 5 body.")

(defconst beamer-gui--tikz-format
  "\\tikz[x=\\paperwidth,y=\\paperheight]{\\useasboundingbox (0,0) rectangle (%s,-%s); %s;}"
  "Format of a TikZ shape body: width, height, draw command.
Coordinates inside are page fractions, y pointing down when negated.")

(defconst beamer-gui--image-regexp
  "\\`[ \t\n]*\\\\includegraphics\\[width=\\\\linewidth\\]{\\([^}]+\\)}[ \t\n]*\\'"
  "Regexp for an image body.  Group 1 is the file name.")

(defconst beamer-gui--arrow-regexp
  (let ((n beamer-gui--number-group))
    (concat "\\\\draw\\[gui arrow,overlay\\] (" n ",-" n ") -- (" n ",-" n ")"))
  "Regexp for an arrow body.  Groups: x1 y1 x2 y2 relative to the block.")

(defconst beamer-gui--ellipse-regexp
  (let ((n beamer-gui--number-group))
    (concat "\\\\draw\\[gui ellipse\\] (" n ",-" n ") ellipse\\[x radius="
            n ",y radius=" n "\\]"))
  "Regexp for an ellipse body.  Groups: cx cy rx ry relative to the block.")

(defconst beamer-gui--brace-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?{ "(}" table)
    (modify-syntax-entry ?} "){" table)
    (modify-syntax-entry ?\\ "\\" table)
    table)
  "Syntax table in which only braces group, for balanced scanning.")


;;;; Utilities

(defun beamer-gui--org-p ()
  "Return non-nil if the current buffer is an Org buffer."
  (derived-mode-p 'org-mode))

(defun beamer-gui--fmt (x)
  "Return number X as a string with at most four decimals."
  (let ((s (string-trim-right (format "%.4f" x) "\\.?0+")))
    (if (member s '("" "-0")) "0" s)))

(defun beamer-gui--match-numbers (string &rest groups)
  "Return the numbers matched by GROUPS of the last match.
STRING is the string searched, or nil for the buffer."
  (mapcar (lambda (g) (string-to-number (match-string g string))) groups))

(defun beamer-gui--item-data (item)
  "Return ITEM without its buffer positions :beg and :end."
  (cl-loop for (key value) on item by #'cddr
           unless (memq key '(:beg :end))
           append (list key value)))


;;;; Elements: parsing and serialization

(defun beamer-gui--parse-body (body x y w)
  "Return the element plist for BODY of a block at X, Y of width W."
  (let ((case-fold-search nil))
    (cond
     ((string-match beamer-gui--image-regexp body)
      (list :kind "image" :x x :y y :w w :file (match-string 1 body)))
     ((string-match beamer-gui--arrow-regexp body)
      (pcase-let ((`(,x1 ,y1 ,x2 ,y2) (beamer-gui--match-numbers body 1 2 3 4)))
        (list :kind "arrow"
              :x1 (+ x x1) :y1 (+ y y1) :x2 (+ x x2) :y2 (+ y y2))))
     ((string-match beamer-gui--ellipse-regexp body)
      (pcase-let ((`(,rx ,ry) (beamer-gui--match-numbers body 3 4)))
        (list :kind "ellipse" :x x :y y :w (* 2 rx) :h (* 2 ry))))
     (t
      (list :kind "raw" :x x :y y :w w :body body)))))

(defun beamer-gui-parse-blocks (beg end)
  "Return the managed blocks between BEG and END as plists.
Each plist has :id, :kind, the geometry of that kind, and the
buffer positions :beg and :end of the block."
  (save-excursion
    (goto-char beg)
    (let (items)
      (while (re-search-forward beamer-gui--block-regexp end t)
        (pcase-let ((`(,w ,x ,y) (beamer-gui--match-numbers nil 1 2 3)))
          (push (append (list :id (match-string 4)
                              :beg (match-beginning 0) :end (match-end 0))
                        (beamer-gui--parse-body (match-string 5) x y w))
                items)))
      (nreverse items))))

(defun beamer-gui--block (id x y w body)
  "Return a managed block ID at X, Y of width W containing BODY."
  (format "\\begin{textblock*}{%s\\paperwidth}(%s\\paperwidth,%s\\paperheight) %% gui:%s\n  %s\n\\end{textblock*}"
          (beamer-gui--fmt w) (beamer-gui--fmt x) (beamer-gui--fmt y) id body))

(defun beamer-gui--tikz (w h draw &rest coordinates)
  "Return a TikZ body of size W by H.
DRAW is a format string for the draw command, filled with
COORDINATES formatted by `beamer-gui--fmt'."
  (format beamer-gui--tikz-format
          (beamer-gui--fmt w) (beamer-gui--fmt h)
          (apply #'format draw (mapcar #'beamer-gui--fmt coordinates))))

(defun beamer-gui-item-to-tex (item)
  "Return the LaTeX block for element ITEM."
  (let ((id (plist-get item :id)))
    (unless (and (stringp id)
                 (string-match-p (concat "\\`" beamer-gui--id-regexp "\\'") id))
      (error "Invalid element id: %S" id))
    (pcase (plist-get item :kind)
      ("image"
       (beamer-gui--block id (plist-get item :x) (plist-get item :y) (plist-get item :w)
                          (format "\\includegraphics[width=\\linewidth]{%s}"
                                  (plist-get item :file))))
      ("arrow"
       ;; The block is the bounding box of the arrow.
       (cl-destructuring-bind (&key x1 y1 x2 y2 &allow-other-keys) item
         (let ((x (min x1 x2)) (y (min y1 y2))
               (w (max (abs (- x2 x1)) 0.001)) (h (max (abs (- y2 y1)) 0.001)))
           (beamer-gui--block
            id x y w
            (beamer-gui--tikz w h "\\draw[gui arrow,overlay] (%s,-%s) -- (%s,-%s)"
                              (- x1 x) (- y1 y) (- x2 x) (- y2 y))))))
      ("ellipse"
       (cl-destructuring-bind (&key x y w h &allow-other-keys) item
         (let ((rx (/ w 2.0)) (ry (/ h 2.0)))
           (beamer-gui--block
            id x y w
            (beamer-gui--tikz w h "\\draw[gui ellipse] (%s,-%s) ellipse[x radius=%s,y radius=%s]"
                              rx ry rx ry)))))
      ("raw"
       (beamer-gui--block id (plist-get item :x) (plist-get item :y) (plist-get item :w)
                          (string-trim (plist-get item :body))))
      (kind (error "Unknown element kind: %S" kind)))))


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
          (when (and (re-search-forward beamer-gui--frame-end-regexp nil t)
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

(defun beamer-gui--delete-block (block)
  "Delete BLOCK together with the line it occupied, if then blank."
  (goto-char (plist-get block :beg))
  (delete-region (point) (plist-get block :end))
  (when (looking-at "[ \t]*\n")
    (delete-region (point) (match-end 0)))
  (when (looking-back "^[ \t]+" (line-beginning-position))
    (delete-region (match-beginning 0) (point))))

(defun beamer-gui-apply-items (beg end items)
  "Make the managed blocks between BEG and END match ITEMS.
Blocks whose id is in ITEMS are rewritten in place, other blocks are
deleted, and items with new ids are appended at the end of the frame
in the order given, so later items are drawn on top.  The whole edit
is a single undo step."
  (let* ((old (beamer-gui-parse-blocks beg end))
         (old-ids (mapcar (lambda (b) (plist-get b :id)) old))
         (new (cl-remove-if (lambda (i) (member (plist-get i :id) old-ids)) items))
         (end-marker (copy-marker end))
         (group (prepare-change-group)))
    (unwind-protect
        (progn
          (activate-change-group group)
          (save-excursion
            ;; Last to first, so earlier positions stay valid.
            (dolist (block (reverse old))
              (let ((item (cl-find (plist-get block :id) items
                                   :key (lambda (i) (plist-get i :id))
                                   :test #'equal)))
                (if (not item)
                    (beamer-gui--delete-block block)
                  (goto-char (plist-get block :beg))
                  (delete-region (point) (plist-get block :end))
                  (insert (beamer-gui-item-to-tex item)))))
            (when new
              (goto-char (beamer-gui--insertion-point beg end-marker))
              (dolist (item new)
                (insert (beamer-gui-item-to-tex item) "\n"))))
          (undo-amalgamate-change-group group)
          (accept-change-group group)
          (setq group nil))
      (when group (cancel-change-group group))
      (set-marker end-marker nil))))


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

(defun beamer-gui-strip-managed (text)
  "Return TEXT without image, arrow and ellipse blocks.
Raw blocks are kept so that their content shows in the background."
  (with-temp-buffer
    (insert text)
    (dolist (block (reverse (beamer-gui-parse-blocks (point-min) (point-max))))
      (unless (equal (plist-get block :kind) "raw")
        (delete-region (plist-get block :beg) (plist-get block :end))))
    (buffer-string)))

(defun beamer-gui-strip-notes (doc)
  "Return DOC with beamer note options commented out.
A frame then compiles to a single slide-sized page."
  (replace-regexp-in-string
   beamer-gui--notes-regexp
   (lambda (match) (concat "% [beamer-gui] " (string-trim match)))
   doc t t))

(defun beamer-gui--body-setup ()
  "Return setup commands between \\begin{document} and the first frame.
See `beamer-gui-body-setup-regexp'.  Arguments may span lines."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward beamer-gui--document-begin-regexp nil t)
      (let ((limit (save-excursion
                     (or (re-search-forward beamer-gui--frame-begin-regexp nil t)
                         (point-max))))
            commands)
        (with-syntax-table beamer-gui--brace-syntax-table
          (while (re-search-forward beamer-gui-body-setup-regexp limit t)
            (let ((start (line-beginning-position)))
              (goto-char (1- (match-end 0)))
              (forward-sexp)
              (push (buffer-substring-no-properties start (line-end-position))
                    commands))))
        (string-join (nreverse commands) "\n")))))

(defun beamer-gui--tex-frame-document (beg)
  "Return a LaTeX document made of the preamble and the frame at BEG."
  (save-excursion
    (let ((frame (beamer-gui-frame-bounds beg))
          (setup (beamer-gui--body-setup))
          (preamble-end (progn (goto-char (point-min))
                               (re-search-forward beamer-gui--document-begin-regexp)
                               (point))))
      (concat (buffer-substring-no-properties (point-min) preamble-end) "\n"
              (if (string-empty-p (or setup "")) "" (concat setup "\n"))
              (buffer-substring-no-properties (car frame) (cdr frame))
              "\n\\end{document}\n"))))

(defun beamer-gui--org-frame-document (beg)
  "Return the beamer export of the Org subtree at BEG."
  (require 'ox-beamer)
  (save-excursion
    (goto-char beg)
    (org-export-as 'beamer t nil nil)))

(defun beamer-gui-frame-document (beg)
  "Return a complete LaTeX document containing only the frame at BEG.
Note options are commented out, see `beamer-gui-strip-notes'."
  (beamer-gui-strip-notes
   (if (beamer-gui--org-p)
       (beamer-gui--org-frame-document beg)
     (beamer-gui--tex-frame-document beg))))


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

(defun beamer-gui-insert-preamble ()
  "Insert `beamer-gui-preamble' before \\begin{document}, unless present."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (if (search-forward beamer-gui--preamble-marker nil t)
        (message "beamer-gui: preamble already present")
      (re-search-forward beamer-gui--document-begin-regexp)
      (forward-line 0)
      (insert beamer-gui-preamble))))


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
  buffer beg end tmpdir process)

(defvar-local beamer-gui--current-session nil
  "The `beamer-gui--session' of this buffer, if any.")

(defun beamer-gui--session-blocks (session)
  "Return the managed blocks of the frame of SESSION."
  (with-current-buffer (beamer-gui--session-buffer session)
    (beamer-gui-parse-blocks (beamer-gui--session-beg session)
                             (beamer-gui--session-end session))))

(defun beamer-gui--compile-background (session callback)
  "Compile the frame of SESSION without its managed shapes.
Call CALLBACK with the PDF file name."
  (with-current-buffer (beamer-gui--session-buffer session)
    (beamer-gui--compile
     (beamer-gui-strip-managed
      (beamer-gui-frame-document (marker-position (beamer-gui--session-beg session))))
     (file-name-directory buffer-file-name)
     (beamer-gui--session-tmpdir session)
     callback)))

(defun beamer-gui--session-file (session pdf)
  "Write the GUI input file of SESSION with background PDF; return its name."
  (with-current-buffer (beamer-gui--session-buffer session)
    (let ((file (expand-file-name "session.json" (beamer-gui--session-tmpdir session)))
          (json (json-serialize
                 (list :background pdf
                       :tex_dir (file-name-directory buffer-file-name)
                       :image_dir (beamer-gui-image-dir)
                       :stem (format "%s-f%d" (file-name-base buffer-file-name)
                                     (beamer-gui-frame-ordinal
                                      (beamer-gui--session-beg session)))
                       :graphics_path (vconcat (beamer-gui-graphics-path))
                       :items (vconcat (mapcar #'beamer-gui--item-data
                                               (beamer-gui--session-blocks session)))))))
      (with-temp-file file (insert json))
      file)))

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
      (beamer-gui-apply-items (marker-position beg) (marker-position end) items)
      (set-marker end (cdr (beamer-gui-frame-bounds beg)))))
  (beamer-gui--compile-background
   session (lambda (pdf) (beamer-gui--send session (list :background pdf)))))

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
              (when items
                (beamer-gui--save-items session items)))))))))

(defun beamer-gui--start-gui (session pdf)
  "Start the GUI process of SESSION with background PDF."
  (setf (beamer-gui--session-process session)
        (make-process
         :name "beamer-gui"
         :buffer (get-buffer-create " *beamer-gui*")
         :command (list beamer-gui-python beamer-gui-script
                        (beamer-gui--session-file session pdf))
         :connection-type 'pipe
         :stderr (get-buffer-create "*beamer-gui-errors*")
         :filter (beamer-gui--filter session))))

;;;###autoload
(defun beamer-gui-edit-frame ()
  "Edit the managed elements of the frame at point in the GUI.
Saving in the GUI rewrites the elements in this buffer."
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
      (beamer-gui--compile-background
       session (lambda (pdf) (beamer-gui--start-gui session pdf)))
      (message "beamer-gui: compiling frame..."))))

;;;; Minor mode

(defvar beamer-gui-mode-map
  (let ((map (make-sparse-keymap)))
    ;; C-c followed by punctuation is the space for minor modes; + is
    ;; not used by AUCTeX or RefTeX.
    (define-key map (kbd "C-c C-g") #'beamer-gui-edit-frame)
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
