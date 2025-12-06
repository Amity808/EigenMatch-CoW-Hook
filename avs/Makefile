DEVKIT_BIN ?= $(HOME)/bin/devkit
AVS_PROJECT_DIR ?= $(CURDIR)/eigenmatch-avs
CONTEXT ?= eigenmatch
DEVNET_CONTEXT ?= devnet
L1_RPC_URL ?= https://eth-sepolia.g.alchemy.com/v2/FlEUrYqZ9gYvgFxtEVA6zWB0zrQwGL4N
L2_RPC_URL ?= https://opt-sepolia.g.alchemy.com/v2/bNbF6GWvzpUzhRHAkH5ejBEfg4GAneIS
DEPLOYER_PK ?= 0x59c6995e998f97a5a004497e5c8c95c200f6351980aaff93d66fa795676b181d
APP_PK ?= 0x885193e06bfcfbff6348f1b9caf486a18c2b927e66382223d7c1cafa9858bb72
AVS_PK ?= 0x043ae9d5e9d02f5d6df1c671c5f3cf1911091cf07bba468e579b843f38cf1d7b
AVS_METADATA_URL ?= https://example.com/eigenmatch-metadata.json
REGISTRAR_ADDRESS ?= 0x0000000000000000000000000000000000000001

.PHONY: bootstrap
bootstrap:
	cd $(AVS_PROJECT_DIR) && mkdir -p config/contexts
	cd $(AVS_PROJECT_DIR) && [ -f config/config.yaml ] || cp config.template.yaml config/config.yaml
	test -x $(AVS_PROJECT_DIR)/.devkit/scripts/deployL1Contracts || ( \
		echo "[bootstrap] missing .devkit/scripts/deployL1Contracts in $(AVS_PROJECT_DIR)" >&2 ; \
		echo "[bootstrap] run 'devkit avs create' inside avs/eigenmatch-avs or copy the Hourglass .devkit folder per context docs" >&2 ; \
		exit 1 )

.PHONY: context
context: bootstrap
	cd $(AVS_PROJECT_DIR) && $(DEVKIT_BIN) avs context create --overwrite --use=false $(DEVNET_CONTEXT)
	cd $(AVS_PROJECT_DIR) && $(DEVKIT_BIN) avs context create --overwrite --use --l1-rpc-url $(L1_RPC_URL) --l2-rpc-url $(L2_RPC_URL) --deployer-private-key $(DEPLOYER_PK) --app-private-key $(APP_PK) --avs-private-key $(AVS_PK) --avs-metadata-url $(AVS_METADATA_URL) --registrar-address $(REGISTRAR_ADDRESS) $(CONTEXT)

.PHONY: devnet-start
devnet-start: bootstrap
	cd $(AVS_PROJECT_DIR) && L1_FORK_URL=$(L1_RPC_URL) L2_FORK_URL=$(L2_RPC_URL) $(DEVKIT_BIN) avs devnet start --context $(DEVNET_CONTEXT)

.PHONY: devnet-stop
devnet-stop:
	cd $(AVS_PROJECT_DIR) && $(DEVKIT_BIN) avs devnet stop --context $(DEVNET_CONTEXT)

