#!/usr/bin/env python3
"""Run the editor on SESSION with random input (or none, with seed
"noop") and write its save message to OUT."""
import os
import sys

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import json  # noqa: E402

from PySide6.QtWidgets import QApplication  # noqa: E402

import gui_fuzz  # noqa: E402

session_file, out_file, seed = sys.argv[1:4]
app = QApplication([])
session = json.load(open(session_file))
captured = []
real_main_save = gui_fuzz.beamer_gui.Editor.save


def save(self):
    captured.append({"items": self.items_dicts(), "background": self.frame_background})


gui_fuzz.beamer_gui.Editor.save = save
errors = gui_fuzz.main(0 if seed == "noop" else 300, 0 if seed == "noop" else int(seed),
                       session)
gui_fuzz.beamer_gui.sys.stdout = sys.__stdout__
json.dump(captured[-1], open(out_file, "w"))
for e in errors[:3]:
    print(e)
sys.exit(1 if errors else 0)
