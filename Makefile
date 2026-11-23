EMACS ?= emacs
PYTHON ?= python3

.PHONY: test test-el test-py test-layout compile clean
test: compile test-el test-py test-layout

compile:
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile beamer-gui.el

test-el:
	$(EMACS) -Q --batch -L . -L test -l test/beamer-gui-test.el -f ert-run-tests-batch-and-exit

test-py:
	QT_QPA_PLATFORM=offscreen $(PYTHON) -m pytest -q test/test_beamer_gui.py

test-layout:
	$(PYTHON) -m pytest -q test/test_layout.py

clean:
	rm -f *.elc
