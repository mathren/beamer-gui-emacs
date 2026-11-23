"""Moving an element must move nothing else on the slide.

Each case writes a frame, moves one element with beamer-gui.el (as
the GUI would), compiles before and after, and compares the position
of every word: the moved element's words must move by exactly the
requested amount, all others must stay within 0.5pt.  A second move
goes through the wrapper written by the first.
"""
import os
import shutil
import subprocess

import pytest

pymupdf = pytest.importorskip("pymupdf")
if not (shutil.which("pdflatex") and shutil.which("emacs")):
    pytest.skip("pdflatex and emacs needed", allow_module_level=True)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HARNESS = os.path.join(ROOT, "test", "layout-harness.el")
TOLERANCE = 0.5   # pt

BODY = r"""  Some text above.
  \begin{center}
    \includegraphics[width=0.2\textwidth]{example-image-a}
  \end{center}
  \begin{block}{Bk}
    Blockword.
  \end{block}
  \begin{tcolorbox}
    Tcbword.
  \end{tcolorbox}
  Middle text.
  \begin{itemize}
  \item Itemword
  \end{itemize}
  After list.
  \begin{textblock*}{3cm}(1cm,0.8\paperheight)
    Tbword
  \end{textblock*}
  \begin{textblock}{2}[0,0](8,13)
    Modword
  \end{textblock}
"""
OWN = {"includegraphics": ["A"], "block": ["Bk", "Blockword."], "tcolorbox": ["Tcbword."],
       "itemize": ["▶Itemword"], "textblock*": ["Tbword"], "textblock": ["Modword"]}


def emacs(form):
    r = subprocess.run(["emacs", "-Q", "--batch", "-L", ROOT, "-l", HARNESS, "--eval", form],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr[-2000:]


def lisp_string(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def compile_words(tex):
    d = os.path.dirname(tex)
    subprocess.run(["pdflatex", "-interaction=nonstopmode", tex], cwd=d, capture_output=True)
    page = pymupdf.open(tex[:-4] + ".pdf")[0]
    return {w[4]: (w[0], w[1]) for w in page.get_text("words")}, page.rect


@pytest.mark.parametrize("valign", ["t", "c"])
@pytest.mark.parametrize("name", list(OWN))
def test_only_the_moved_element_moves(tmp_path, valign, name):
    tex = str(tmp_path / "slides.tex")
    emacs(f"(layout-write {lisp_string(tex)} {lisp_string(valign)} {lisp_string(BODY)})")
    before, page = compile_words(tex)
    emacs(f'(layout-move {lisp_string(tex)} {lisp_string(name)} 0.25)')
    emacs(f'(layout-move {lisp_string(tex)} {lisp_string(name)} 0 0.1)')
    after, _ = compile_words(tex)
    dx, dy = 0.25 * page.width, 0.1 * page.height
    errors = []
    for word, (x, y) in before.items():
        ex, ey = (x + dx, y + dy) if word in OWN[name] else (x, y)
        got = after.get(word)
        if got is None or abs(got[0] - ex) > TOLERANCE or abs(got[1] - ey) > TOLERANCE:
            errors.append((word, got and (round(got[0] - ex, 2), round(got[1] - ey, 2))))
    assert not errors
