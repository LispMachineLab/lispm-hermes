EMACS ?= emacs
# lisp/ of LispM Desktop, whose editor this extends: a checkout beside
# this one by default.
LISPM_DESKTOP ?= ../lispm-desktop/lisp

.PHONY: test compile

test:
	$(EMACS) -Q --batch -L . -L $(LISPM_DESKTOP) -l test/lispm-hermes-test.el \
	  -f ert-run-tests-batch-and-exit

# A check: the .elc file is removed again, as it would shadow the source
# of a checkout Emacs loads from.
compile:
	$(EMACS) -Q --batch -L . -L $(LISPM_DESKTOP) --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile lispm-hermes.el; \
	status=$$?; rm -f lispm-hermes.elc; exit $$status
