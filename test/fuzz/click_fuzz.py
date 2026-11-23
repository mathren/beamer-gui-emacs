#!/usr/bin/env python3
"""Click every word of random frames; Emacs must land on that word.

Usage: click_fuzz.py [N] [SEED]

For each generated frame (after random edits, so that moved elements
are included), every word on the slide is clicked at its centre, as
the GUI does; the source text at the position Emacs jumps to must
start with that word.  Reports the misses."""
import json
import os
import random
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, ROOT)
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
import fuzz  # noqa: E402

from PySide6.QtCore import QPointF  # noqa: E402
from PySide6.QtWidgets import QApplication  # noqa: E402

import beamer_gui  # noqa: E402


def case(seed, pre, app):
    rng = random.Random(seed)
    work = tempfile.mkdtemp(prefix=f"click{seed}-")
    tex = os.path.join(work, "slides.tex")
    open(tex, "w").write(fuzz.document(fuzz.Gen(rng), pre))
    if rng.random() < 0.5:                         # include moved elements
        fuzz.emacs(f"(fuzz-step {fuzz.lisp(tex)} {seed} {fuzz.lisp(tex + '.j')})")
    sess = tex + ".session.json"
    code, err = fuzz.emacs(f"(fuzz-session {fuzz.lisp(tex)} {fuzz.lisp(sess)})")
    if code:
        return None, [f"session: {err[-300:]}"]
    ed = beamer_gui.Editor(json.load(open(sess)), listen_stdin=False)
    clicks = []
    for x0, y0, x1, y1, text in ed.page_words:
        info = ed.click_info(QPointF((x0 + x1) / 2 * ed.W, (y0 + y1) / 2 * ed.H))
        if info["word"]:
            clicks.append(info)
    ed.close()
    json.dump(clicks, open(tex + ".clicks", "w"))
    code, err = fuzz.emacs(f"(fuzz-clicks {fuzz.lisp(tex)} {fuzz.lisp(tex + '.clicks')} "
                           f"{fuzz.lisp(tex + '.landed')})")
    if code:
        return None, [f"clicks: {err[-300:]}"]
    landed = json.load(open(tex + ".landed"))
    misses = [(c["word"], got, c["element"]) for c, got in zip(clicks, landed)
              if not (got == c["word"] or (c.get("raw") and got == c["raw"][:len(got)]))]
    return len(clicks), misses


if __name__ == "__main__":
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 10
    seed0 = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    app = QApplication([])
    pre = fuzz.preamble()
    total = missed = 0
    for seed in range(seed0, seed0 + n):
        count, misses = case(seed, pre, app)
        if count is None:
            print(f"seed {seed}: ERROR {misses}")
            continue
        total += count
        missed += len(misses)
        print(f"seed {seed}: {count} words, {len(misses)} missed {misses[:6]}", flush=True)
    print(f"{total - missed}/{total} words found")
