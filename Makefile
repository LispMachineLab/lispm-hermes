EMACS ?= emacs
# lisp/ of lispm-agent, whose editor's agents this adds to: a checkout
# beside this one by default.
LISPM_AGENT ?= ../lispm-agent/lisp
# LispM Kit, whose engine translates the agent's words: a checkout beside
# this one by default.
LISPM_KIT ?= ../lispm-kit

.PHONY: test compile

test:
	$(EMACS) -Q --batch -L . -L $(LISPM_KIT) -L $(LISPM_AGENT) -l test/lispm-hermes-test.el \
	  -f ert-run-tests-batch-and-exit

# A check: the .elc file is removed again, as it would shadow the source
# of a checkout Emacs loads from.
compile:
	$(EMACS) -Q --batch -L . -L $(LISPM_KIT) -L $(LISPM_AGENT) --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile lispm-hermes.el; \
	status=$$?; rm -f lispm-hermes.elc; exit $$status
