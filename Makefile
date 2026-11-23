EMACS ?= emacs
PYTHON ?= python3

.PHONY: test test-el test-py test-layout fuzz compile clean
test: compile test-el test-py test-layout

compile:
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile beamer-gui.el

test-el:
	$(EMACS) -Q --batch -L . -L test -l test/beamer-gui-test.el -f ert-run-tests-batch-and-exit

test-py:
	QT_QPA_PLATFORM=offscreen $(PYTHON) -m pytest -q test/test_beamer_gui.py

test-layout:
	$(PYTHON) -m pytest -q test/test_layout.py

# Random documents, edits and GUI input; minutes per run, not part of test.
fuzz:
	$(PYTHON) test/fuzz/fuzz.py 20
	QT_QPA_PLATFORM=offscreen $(PYTHON) test/fuzz/gui_fuzz.py 400
	$(PYTHON) test/fuzz/loop_fuzz.py 10

clean:
	rm -f *.elc
