"""Stand-in for beamer_gui.py: moves first item, adds an arrow, saves,
then records the background message from Emacs in DONE file."""
import json
import os
import sys

s = json.load(open(sys.argv[1]))
items = s["items"]
items[0]["x"] = 0.5
items.append({"kind": "arrow", "id": "arrow9", "x1": 0.1, "y1": 0.1, "x2": 0.3, "y2": 0.3})
print(json.dumps({"items": items}), flush=True)
line = sys.stdin.readline()
tmp = os.path.join(s["tex_dir"], "done.tmp")
with open(tmp, "w") as f:
    f.write(line)
os.rename(tmp, os.path.join(s["tex_dir"], "done.txt"))
