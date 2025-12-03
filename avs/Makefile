DEVKIT_BIN ?= $(CURDIR)/devkit/bin/devkit
CONTEXT ?= eigenmatch

.PHONY: context
context:
	cd devkit && $(DEVKIT_BIN) context create $(CONTEXT) --template avs --force

.PHONY: devnet-start
devnet-start:
	cd devkit && $(DEVKIT_BIN) avs devnet start --context $(CONTEXT)

.PHONY: devnet-stop
devnet-stop:
	cd devkit && $(DEVKIT_BIN) avs devnet stop --context $(CONTEXT)

