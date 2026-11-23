#!/usr/bin/env python3
"""Random mouse and keyboard input on the editor, offscreen.

Usage: gui_fuzz.py [N_EVENTS] [SEED]

Fails on any Python exception (including those PySide reports from
Qt callbacks), and on saved items that are not finite numbers inside
a sane range.  Modal dialogs are replaced by instant answers."""
import json
import math
import os
import random
import sys

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, "test"))

from PySide6.QtCore import QEvent, QPointF, Qt  # noqa: E402
from PySide6.QtGui import QMouseEvent  # noqa: E402
from PySide6.QtWidgets import QApplication  # noqa: E402

import beamer_gui  # noqa: E402

ERRORS = []


def hook(kind, value, tb):
    import traceback
    ERRORS.append("".join(traceback.format_exception(kind, value, tb)))


sys.excepthook = hook
sys.unraisablehook = lambda u: ERRORS.append(repr(u.exc_value))


def check_items(items):
    for item in items:
        for k, v in item.items():
            values = v if isinstance(v, list) else [v]
            for x in values:
                if isinstance(x, float) and (not math.isfinite(x) or abs(x) > 10):
                    ERRORS.append(f"bad value {k}={x} in {item['id']}")


def main(n, seed, session):
    rng = random.Random(seed)
    app = QApplication.instance() or QApplication([])
    QApplication.clipboard().setImage(beamer_gui.placeholder_pixmap().toImage())
    beamer_gui.QInputDialog.getMultiLineText = staticmethod(
        lambda *a: (rng.choice(["x", "", "$a_1$ \\\\ b", "{"]), True))
    beamer_gui.BackgroundDialog.exec = lambda self: (
        self.tint.setValue(rng.randint(5, 100)),
        self.color.setCurrentIndex(rng.randrange(self.color.count())), True)[-1]
    out = []
    beamer_gui.sys.stdout = type("W", (), {"write": lambda s, t: out.append(t),
                                           "flush": lambda s: None})()
    ed = beamer_gui.Editor(session, listen_stdin=False)
    ed.show()
    view = ed.view
    vp = view.viewport()

    def mouse(kind, p, button, buttons):
        QApplication.sendEvent(vp, QMouseEvent(kind, QPointF(p), QPointF(vp.mapToGlobal(p)),
                                               button, buttons, Qt.NoModifier))

    keys = [(Qt.Key_A, Qt.NoModifier), (Qt.Key_E, Qt.NoModifier), (Qt.Key_R, Qt.NoModifier),
            (Qt.Key_T, Qt.NoModifier), (Qt.Key_S, Qt.NoModifier), (Qt.Key_B, Qt.NoModifier),
            (Qt.Key_Delete, Qt.NoModifier), (Qt.Key_V, Qt.ControlModifier),
            (Qt.Key_S, Qt.ControlModifier)]
    for i in range(n):
        r = rng.random()
        if r < 0.15:
            key, mod = rng.choice(keys)
            for action in ed.findChildren(beamer_gui.QAction):
                sequence = beamer_gui.QKeySequence(int(key) | int(mod.value))
                if (action.shortcut().matches(sequence)
                        == beamer_gui.QKeySequence.SequenceMatch.ExactMatch):
                    action.trigger()
                    break
        else:
            # Aim at an element (or one of its handles) most of the time.
            targets = [e for e in ed.elements]
            if targets and rng.random() < 0.8:
                e = rng.choice(targets)
                pts = list(getattr(e, "handle_points", lambda: {})().values()) or \
                    [h.pos() for h in getattr(e, "handles", [])] or [e.boundingRect().center()]
                start = view.mapFromScene(e.mapToScene(rng.choice(pts)))
            else:
                start = view.mapFromScene(QPointF(rng.uniform(-100, ed.W + 100),
                                                  rng.uniform(-100, ed.H + 100)))
            if r < 0.2:
                mouse(QEvent.MouseButtonDblClick, start, Qt.LeftButton, Qt.LeftButton)
                continue
            mouse(QEvent.MouseButtonPress, start, Qt.LeftButton, Qt.LeftButton)
            p = start
            for _ in range(rng.randint(1, 8)):
                p = p + type(p)(rng.randint(-120, 120), rng.randint(-120, 120))
                mouse(QEvent.MouseMove, p, Qt.NoButton, Qt.LeftButton)
            mouse(QEvent.MouseButtonRelease, p, Qt.LeftButton, Qt.NoButton)
        app.processEvents()
        if i % 25 == 0:
            check_items(ed.items_dicts())
    ed.save()
    beamer_gui.sys.stdout = sys.__stdout__
    for line in out:
        if line.strip():
            message = json.loads(line)
            check_items(message["items"])
    return ERRORS


if __name__ == "__main__":
    import shutil
    import subprocess
    import tempfile
    QApplication([])
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 500
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    d = tempfile.mkdtemp()
    tex = os.path.join(d, "bg.tex")
    open(tex, "w").write("\\documentclass{beamer}\\definecolor{bblue}{HTML}{144b7a}"
                         "\\begin{document}\\begin{frame}A\\end{frame}\\begin{frame}B"
                         "\\end{frame}\\begin{frame}[plain]\\textcolor{bblue}{\\rule{3mm}{3mm}}"
                         "\\end{frame}\\end{document}")
    subprocess.run(["pdflatex", "-interaction=nonstopmode", "bg.tex"], cwd=d,
                   capture_output=True)
    os.makedirs(os.path.join(d, "fig_slides"))
    beamer_gui.placeholder_pixmap().save(os.path.join(d, "fig_slides", "g.png"))
    from test_beamer_gui import ITEMS
    session = {"background": os.path.join(d, "bg.pdf"), "page_a": 0, "page_b": 1,
               "page_s": 2, "paper": [364.2, 273.1],
               "colors": [{"name": "bblue", "x": 0.1, "y": 0.1}],
               "tex_dir": d, "image_dir": os.path.join(d, "fig_slides"), "stem": "f",
               "items": [dict(i) for i in ITEMS],
               "frame_background": {"color": "", "image": ""}}
    try:
        errors = main(n, seed, session)
    except Exception:
        import traceback
        errors = ERRORS + [traceback.format_exc()]
    finally:
        beamer_gui.sys.stdout = sys.__stdout__
        shutil.rmtree(d)
    for e in errors[:5]:
        print(e)
    print(f"seed {seed}: {len(errors)} errors")
    sys.exit(1 if errors else 0)
