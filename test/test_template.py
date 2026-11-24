"""Move every element of the frames of the bundled beamer template.

Uses beamer_template_mrenzo (a git submodule: git submodule update
--init) as an example of a real talk.  Each movable element of each
frame is moved sideways, then, through its wrapper, down.  The words
that move must all be on one page and move by exactly that much;
every other word of the document must stay within 0.5pt.
"""
import json
import os
import shutil
import subprocess
from collections import Counter

import pytest

pymupdf = pytest.importorskip("pymupdf")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEMPLATE = os.path.join(ROOT, "beamer_template_mrenzo")
HARNESS = os.path.join(ROOT, "test", "layout-harness.el")
if not os.path.exists(os.path.join(TEMPLATE, "template.tex")):
    pytest.skip("submodule beamer_template_mrenzo not checked out", allow_module_level=True)
if not (shutil.which("pdflatex") and shutil.which("emacs")):
    pytest.skip("pdflatex and emacs needed", allow_module_level=True)
TOL = 0.5


def emacs(form):
    r = subprocess.run(["emacs", "-Q", "--batch", "-L", ROOT, "-l", HARNESS, "--eval", form],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr[-1500:]


def q(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def words(tex):
    # Twice: section pages and the like depend on the .aux and .toc files.
    for _ in range(2):
        r = subprocess.run(["pdflatex", "-interaction=nonstopmode", "-halt-on-error", tex],
                           cwd=os.path.dirname(tex), capture_output=True, text=True)
        assert r.returncode == 0, r.stdout[-1500:]
    doc = pymupdf.open(tex[:-4] + ".pdf")
    found = {}
    for i, page in enumerate(doc):
        ws = page.get_text("words")
        counts = Counter(w[4] for w in ws)
        for w in ws:
            if counts[w[4]] == 1:                   # unique on its page
                found[(i, w[4])] = (w[0], w[1])
    return found, doc[0].rect


# The template may hold images pasted with beamer-gui: copy all of it,
# but not its git data or LaTeX output.
IGNORE = shutil.ignore_patterns(".git", "*.aux", "*.log", "*.nav", "*.out", "*.snm",
                                "*.toc", "*.pdf", "*.synctex.gz")


@pytest.fixture(scope="module")
def deck(tmp_path_factory):
    d = tmp_path_factory.mktemp("template") / "deck"
    shutil.copytree(TEMPLATE, d, ignore=IGNORE)
    tex = str(d / "template.tex")
    emacs(f"(with-current-buffer (find-file-noselect {q(tex)}) "
          "(beamer-gui-insert-preamble) (save-buffer))")
    emacs(f"(layout-elements {q(tex)} {q(tex + '.json')})")
    return tex, json.load(open(tex + ".json"))


def cases():
    tex = os.path.join(TEMPLATE, "template.tex")
    if not os.path.exists(tex):
        return []
    import tempfile
    d = tempfile.mkdtemp()
    out = os.path.join(d, "e.json")
    subprocess.run(["emacs", "-Q", "--batch", "-L", ROOT, "-l", HARNESS, "--eval",
                    f"(layout-elements {q(tex)} {q(out)})"], capture_output=True)
    if not os.path.exists(out):
        return []
    return [(f["frame"], e) for f in json.load(open(out)) for e in f["elements"]]


@pytest.mark.parametrize("frame,element", cases())
def test_move_template_element(deck, tmp_path, frame, element):
    src, _ = deck
    shutil.copytree(os.path.dirname(src), tmp_path, dirs_exist_ok=True, ignore=IGNORE)
    tex = str(tmp_path / "template.tex")
    before, page = words(tex)
    dx, dy = 0.05, 0.04
    emacs(f"(layout-move-in-frame {q(tex)} {frame} {q(element)} {dx})")
    after_id = "w1"     # the wrapped element's new id, or its textblock id
    with open(tex) as f:
        text = f.read()
    after_id = "tb1" if "beamer-gui tb1" in text else after_id
    emacs(f"(layout-move-in-frame {q(tex)} {frame} {q(after_id)} 0 {dy})")
    after, _ = words(tex)
    moved = {k: (after[k][0] - x, after[k][1] - y) for k, (x, y) in before.items()
             if k in after and (abs(after[k][0] - x) > TOL or abs(after[k][1] - y) > TOL)}
    missing = [k for k in before if k not in after]
    assert not missing, missing
    pages = {k[0] for k in moved}
    assert len(pages) <= 1, f"words moved on several pages: {moved}"
    want = (dx * page.width, dy * page.height)
    wrong = {k: v for k, v in moved.items()
             if abs(v[0] - want[0]) > TOL or abs(v[1] - want[1]) > TOL}
    assert not wrong, f"words moved by the wrong amount: {wrong}"
