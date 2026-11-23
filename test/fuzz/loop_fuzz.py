#!/usr/bin/env python3
"""Full loop: random document, real session, random GUI input, Emacs
applies the save, the document must compile, and a no-op save after
that must leave it unchanged.  Usage: loop_fuzz.py [N] [SEED]"""
import os
import random
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fuzz  # noqa: E402

GUI = os.path.join(HERE, "gui_driver.py")


def case(seed, pre):
    rng = random.Random(seed)
    work = tempfile.mkdtemp(prefix=f"loop{seed}-")
    tex = os.path.join(work, "slides.tex")
    open(tex, "w").write(fuzz.document(fuzz.Gen(rng), pre))
    shutil.copy(tex, tex + ".orig")
    sess, msg = tex + ".session.json", tex + ".save.json"
    code, err = fuzz.emacs(f"(fuzz-session {fuzz.lisp(tex)} {fuzz.lisp(sess)})")
    if code:
        return [f"session: {err[-600:]}"], work
    r = subprocess.run([sys.executable, GUI, sess, msg, str(seed)], capture_output=True,
                       text=True, timeout=200)
    if r.returncode:
        return [f"GUI: {r.stdout[-800:]} {r.stderr[-800:]}"], work
    code, err = fuzz.emacs(f"(fuzz-apply {fuzz.lisp(tex)} {fuzz.lisp(msg)})")
    if code:
        return [f"apply: {err[-800:]}"], work
    words, errors = fuzz.compile_words(tex)
    if words is None:
        return [f"does not compile: {errors}"], work
    # The editor reloads after a save; saving again without changes
    # must not change the file.
    code, err = fuzz.emacs(f"(fuzz-session {fuzz.lisp(tex)} {fuzz.lisp(sess)})")
    if code:
        return [f"second session: {err[-600:]}"], work
    r = subprocess.run([sys.executable, GUI, sess, msg, "noop"], capture_output=True,
                       text=True, timeout=200)
    if r.returncode:
        return [f"GUI no-op: {r.stderr[-600:]}"], work
    before = open(tex).read()
    code, err = fuzz.emacs(f"(fuzz-apply {fuzz.lisp(tex)} {fuzz.lisp(msg)})")
    if code:
        return [f"no-op apply: {err[-600:]}"], work
    if open(tex).read() != before:
        return ["saving the reloaded editor without changes changed the file"], work
    return [], work


if __name__ == "__main__":
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 10
    seed0 = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    pre = fuzz.preamble()
    bad = 0
    for seed in range(seed0, seed0 + n):
        problems, work = case(seed, pre)
        if problems:
            bad += 1
            dest = os.path.join(HERE, "fuzz-failures", f"loop{seed}")
            shutil.rmtree(dest, ignore_errors=True)
            shutil.copytree(work, dest)
        print(f"seed {seed}: " + ("ok" if not problems else "FAIL\n    " + "\n    ".join(problems)),
              flush=True)
    print(f"{bad} failing of {n}")
