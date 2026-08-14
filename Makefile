EMACS ?= emacs

.PHONY: test
test:
	$(EMACS) --batch -L . \
		-l ert \
		-l mu4e-hubspot-api.el \
		-l mu4e-hubspot.el \
		-l tests/mu4e-hubspot-api-test.el \
		-l tests/mu4e-hubspot-test.el \
		-f ert-run-tests-batch-and-exit
