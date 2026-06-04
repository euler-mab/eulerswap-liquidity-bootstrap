# Self-documenting Makefile. Run `make` to see available targets.
#
# This is a convenience layer over commands documented in the README and walkthrough.
# Mainnet broadcasts are NOT exposed as targets — they stay as explicit
# `forge script ... --broadcast` commands in docs/WALKTHROUGH.md.

.PHONY: help setup test fork-test demo doctor clean

help:                                ## Show this help (default target)
	@echo "Usage: make <target>"
	@echo ""
	@awk -F ':.*## ' '/^[a-z][a-zA-Z0-9_-]*:.*## / { printf "  %-18s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

setup:                               ## One-time: pull submodules and build
	forge install
	forge build

test:                                ## Run unit tests (no RPC required)
	forge test --no-match-path "test/*.fork.t.sol"

fork-test: check-rpc                 ## Run mainnet-fork tests (needs MAINNET_RPC_URL)
	forge test --match-path "test/*.fork.t.sol" --fork-url $$MAINNET_RPC_URL -vv

demo: check-rpc                      ## Anvil end-to-end demo: deploy a mini market on forked mainnet
	./bin/anvil-demo.sh

doctor:                              ## Preflight: foundry, submodules, env
	./bin/doctor.sh

clean:                               ## Remove build artifacts
	forge clean

check-rpc:
	@if [ -z "$$MAINNET_RPC_URL" ]; then \
		echo "MAINNET_RPC_URL is not set. Copy .env.example to .env and fill it in,"; \
		echo "then 'source .env' or 'export MAINNET_RPC_URL=...' before running."; \
		exit 1; \
	fi
