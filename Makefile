EMACS ?= emacs
PYTHON ?= python3

.PHONY: test test-el test-py test-layout fuzz lint checkdoc package-lint docs compile clean
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
	QT_QPA_PLATFORM=offscreen $(PYTHON) test/fuzz/click_fuzz.py 10

lint: checkdoc package-lint

checkdoc:
	$(EMACS) -batch -Q -L . -l tools/checkdoc.el beamer-gui.el

# package-lint as MELPA runs it.  It has to be installed: from MELPA, or
# PACKAGE_LINT_DIR naming a checkout.
package-lint:
	$(EMACS) -batch -Q $(if $(PACKAGE_LINT_DIR),-L $(PACKAGE_LINT_DIR),) \
	  --eval "(progn (require 'package) (package-initialize) (require 'package-lint))" \
	  -f package-lint-batch-and-exit beamer-gui.el

# docs/*.org to the site, in html-content/; the GIF is shared with README.org.
docs:
	$(EMACS) -batch -Q -l publish.el all
	python3 tools/check-links.py html-content

clean:
	rm -f *.elc
