#!/usr/bin/env python3
"""Fuzz beamer-gui with random frames and random user edits.

Usage: fuzz.py [N] [SEED]

Each case writes a random frame built from many kinds of LaTeX,
then makes random edits through beamer-gui.el the way the GUI does
(moves, resizes, new shapes, styles, deletions, backgrounds) and
checks:
  - the document still compiles;
  - words outside the edited elements do not move (0.5pt), in frames
    that fit on the slide (TeX shrinks the skips of overfull frames);
  - words of a moved, unresized element move by exactly the move;
  - sending the items back unchanged leaves the file unchanged;
  - a second round of edits on the result also compiles.
Failing cases are kept in fuzz-failures/.
"""
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile

import pymupdf

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
TOL = 0.5
UNIQUE = r"E\d+w|Plainword\d+|T\d+|A\d+|Box\d+|L\d+|V\d+|H\d+"


def emacs(form):
    r = subprocess.run(["emacs", "-Q", "--batch", "-L", ROOT, "-l",
                        os.path.join(HERE, "fuzz-harness.el"), "--eval", form],
                       capture_output=True, text=True, timeout=300)
    return r.returncode, r.stderr


def lisp(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


class Gen:
    """Random frame; each element has its own words E<n>w<k>."""

    def __init__(self, rng):
        self.rng = rng
        self.elements = []      # (name, words) in text order
        self.n = 0
        self.plain = 0

    def word(self, n):
        return f"E{n}w"

    def plain_text(self):
        self.plain += 1
        return f"Plainword{self.plain} text."

    def element(self, depth=0):
        r = self.rng
        self.n += 1
        n, w = self.n, self.word(self.n)
        kind = r.choice(["image", "block", "alertblock", "tcolorbox", "itemize", "tabular",
                         "textblock*", "textblock", "enumerate", "tikzpicture",
                         "member", "varblock", "movie"])
        width = r.choice(["0.2\\textwidth", "3cm", "0.3\\linewidth"])
        code = {
            "image": f"\\includegraphics[width={width}]{{example-image-a}}",
            "block": (f"\\begin{{block}}{{T{n}}}\n  {w} block text"
                      " % \\begin{block} in a comment\n\\end{block}"),
            "alertblock": f"\\begin{{alertblock}}{{A{n}}}\n  {w}\n\\end{{alertblock}}",
            "tcolorbox": (f"\\begin{{tcolorbox}}[colback=red!5,title=Box{n}]\n  {w}\n"
                          "\\end{tcolorbox}"),
            "itemize": f"\\begin{{itemize}}\n\\item {w}\n\\item more\n\\end{{itemize}}",
            "enumerate": f"\\begin{{enumerate}}\n\\item {w}\n\\end{{enumerate}}",
            "tabular": f"\\begin{{tabular}}{{|c|c|}}\\hline {w} & b\\\\\\hline\\end{{tabular}}",
            "textblock*": (f"\\begin{{textblock*}}{{3cm}}({r.uniform(0.5, 6):.2f}cm,"
                           f"{r.uniform(0.5, 0.8):.2f}\\paperheight)\n  {w}\n\\end{{textblock*}}"),
            "textblock": (f"\\begin{{textblock}}{{2}}[0,0]({r.uniform(1, 8):.1f},"
                          f"{r.uniform(1, 7):.1f})\n  {w}\n\\end{{textblock}}"),
            "tikzpicture": f"\\begin{{tikzpicture}}\\node[draw] {{{w}}};\\end{{tikzpicture}}",
            "member": (f"\\member{r.choice(['', '[30pt]'])}{{example-image-b}}"
                       f"{{{w}}}{{L{n}}}"),
            "varblock": (f"\\begin{{varblock}}{r.choice(['', '<1->', '[0.5\\textwidth]'])}"
                         f"{{V{n}}}\n  {w}\n\\end{{varblock}}"),
            "movie": f"\\movie[width=2cm,height=1cm]{{{w}}}{{film{n}.mp4}}",
        }[kind]
        if r.random() < 0.2:            # annotations, not elements
            code += f" \\tikzmark{{m{n}}}\\hcancel{{H{n}}}"
        name = {"image": "includegraphics"}.get(kind, kind)
        words = [] if kind == "image" else [w]
        if kind == "tcolorbox":
            words = [w, f"Box{n}"]
        if kind == "block":
            words = [w, f"T{n}"]
        if kind == "alertblock":
            words = [w, f"A{n}"]
        if kind == "member":
            words = [w, f"L{n}"]
        if kind == "varblock":
            words = [w, f"V{n}"]
        self.elements.append((name, words))
        wrap = r.random()
        if kind in ("image", "tabular", "tikzpicture") and wrap < 0.4:
            return f"\\begin{{center}}\n  {code}\n\\end{{center}}"
        if wrap < 0.15 and depth == 0:
            inner = self.element(depth + 1)
            return (f"\\begin{{columns}}\n\\begin{{column}}{{0.45\\textwidth}}\n{code}\n"
                    f"\\end{{column}}\n\\begin{{column}}{{0.45\\textwidth}}\n{inner}\n"
                    f"\\end{{column}}\n\\end{{columns}}")
        if wrap < 0.22 and kind == "image":
            return f"\\only<1->{{{code}}}"
        return code

    def frame(self):
        r = self.rng
        opts = r.choice(["", "[t]", "[c]", "[fragile]", "[t,fragile]"])
        parts = [self.plain_text()]
        for _ in range(r.randint(1, 4)):
            parts.append(self.element())
            if r.random() < 0.6:
                parts.append(self.plain_text())
        if "fragile" in opts and r.random() < 0.7:
            parts.append("\\begin{verbatim}\n\\begin{block}{not an element}\n\\end{verbatim}")
        if r.random() < 0.3:
            parts.append("% \\includegraphics{commented-out}")
        body = "\n".join(parts)
        return (f"\\begin{{frame}}{opts}{{Fuzz}}\n{body}\n\\end{{frame}}\n"
                "\\begin{frame}{Other}\nOtherframeword\n\\end{frame}\n")


# Definitions in the style of beamer_template_mrenzo's setup.tex.
DEFINITIONS = r"""\usepackage{multimedia}
\newcommand\tikzmark[1]{\tikz[remember picture,overlay]\node (#1) {};}
\newcommand{\hcancel}[1]{\tikz[baseline=(t.base)]{\node[inner sep=0pt] (t) {#1};}}
\newcommand{\member}[4][40pt]{%
  \begin{tabular}[t]{@{}c@{}}\includegraphics[width=#1]{#2}\\#3\\#4\end{tabular}}
\newenvironment<>{varblock}[2][.9\textwidth]{%
  \begin{actionenv}#3\def\insertblocktitle{#2}\par\usebeamertemplate{block begin}}
  {\par\usebeamertemplate{block end}\end{actionenv}}
"""


def document(gen, preamble):
    return ("\\documentclass{beamer}\n\\usepackage{tcolorbox}\n\\usepackage{tikz}\n"
            + DEFINITIONS + preamble + "\\begin{document}\n" + gen.frame()
            + "\\end{document}\n")


def compile_words(tex):
    d = os.path.dirname(tex)
    r = subprocess.run(["pdflatex", "-interaction=nonstopmode", "-halt-on-error",
                        os.path.basename(tex)], cwd=d, capture_output=True, text=True)
    if r.returncode:
        err = re.findall(r"^!.*", r.stdout, re.M)
        return None, err[:3]
    compile_words.overfull = "Overfull \\vbox" in r.stdout
    doc = pymupdf.open(tex[:-4] + ".pdf")
    # Last slide of the first frame: the page before "Otherframeword".
    other = next(i for i, p in enumerate(doc) if "Otherframeword" in p.get_text())
    page = doc[other - 1]
    # Only the generated words, unique by construction, are compared.
    words = {}
    for w in page.get_text("words"):
        if re.fullmatch(UNIQUE, w[4]):
            words[w[4]] = (w[0], w[1])
    return words, page.rect


def preamble():
    r = subprocess.run(["emacs", "-Q", "--batch", "-L", ROOT, "--eval",
                        "(progn (require 'beamer-gui) (princ beamer-gui-preamble))"],
                       capture_output=True, text=True)
    return r.stdout


def run_case(seed, pre, outdir):
    rng = random.Random(seed)
    gen = Gen(rng)
    work = tempfile.mkdtemp(prefix=f"fuzz{seed}-")
    tex = os.path.join(work, "slides.tex")
    with open(tex, "w") as f:
        f.write(document(gen, pre))
    shutil.copy(tex, tex + ".orig")
    problems = []

    before, page = compile_words(tex)
    if before is None:
        return [f"generated document does not compile: {page}"], work
    # In a frame too tall for the slide, TeX shrinks its skips, and
    # positions depend on the whole frame: only exact for frames that fit.
    check_positions = not compile_words.overfull
    # 1. no-op save leaves the file unchanged
    code, err = emacs(f"(fuzz-step {lisp(tex)} {seed} {lisp(tex + '.json')} t)")
    if code:
        return [f"no-op step failed: {err[-600:]}"], work
    if json.load(open(tex + ".json"))["changed"] is not False:
        problems.append("no-op save changed the file")
    # 2. random edits
    code, err = emacs(f"(fuzz-step {lisp(tex)} {seed} {lisp(tex + '.json')})")
    if code:
        return problems + [f"edit step failed: {err[-800:]}"], work
    report = json.load(open(tex + ".json"))
    after, _ = compile_words(tex)
    if after is None:
        return problems + [f"edited document does not compile: {_}"], work
    # word positions
    moved_words, resized_words = {}, set()
    id_to_element = {f"c{i + 1}": e for i, e in enumerate(gen.elements)}
    for m in report["moved"]:
        name, words = id_to_element.get(m["id"], (None, []))
        if name != m["name"]:
            problems.append(f"element {m['id']} is {m['name']}, generator says {name}")
            continue
        if abs(m["factor"] - 1) > 1e-9:
            resized_words.update(words)
        else:
            for w in words:
                moved_words[w] = (m["dx"] * page.width, m["dy"] * page.height)
    for w, (x, y) in (before.items() if check_positions else ()):
        if w in resized_words or w not in after and w in moved_words:
            continue
        dx, dy = moved_words.get(w, (0, 0))
        got = after.get(w)
        if got is None:
            # a moved element may end up off the page
            if w not in moved_words:
                problems.append(f"word {w} disappeared")
            continue
        if abs(got[0] - x - dx) > TOL or abs(got[1] - y - dy) > TOL:
            problems.append(f"word {w}: off by ({got[0] - x - dx:.2f}, {got[1] - y - dy:.2f})"
                            + (" [moved]" if w in moved_words else ""))
    # 3. no-op on the edited file, then a second round of edits
    code, err = emacs(f"(fuzz-step {lisp(tex)} {seed} {lisp(tex + '.json')} t)")
    if code:
        problems.append(f"second no-op failed: {err[-600:]}")
    elif json.load(open(tex + ".json"))["changed"] is not False:
        problems.append("no-op save after edits changed the file")
    code, err = emacs(f"(fuzz-step {lisp(tex)} {seed + 1000} {lisp(tex + '.json')})")
    if code:
        problems.append(f"second edit step failed: {err[-800:]}")
    else:
        again, err2 = compile_words(tex)
        if again is None:
            problems.append(f"twice-edited document does not compile: {err2}")
    return problems, work


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 20
    seed0 = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    pre = preamble()
    outdir = os.path.join(HERE, "fuzz-failures")
    failures = 0
    for seed in range(seed0, seed0 + n):
        problems, work = run_case(seed, pre, outdir)
        if problems:
            failures += 1
            os.makedirs(outdir, exist_ok=True)
            dest = os.path.join(outdir, f"seed{seed}")
            shutil.rmtree(dest, ignore_errors=True)
            shutil.copytree(work, dest)
            print(f"seed {seed}: FAIL")
            for p in problems:
                print("   ", p)
        else:
            print(f"seed {seed}: ok")
        sys.stdout.flush()
    print(f"{failures} failing of {n}")
    return failures


if __name__ == "__main__":
    sys.exit(1 if main() else 0)
