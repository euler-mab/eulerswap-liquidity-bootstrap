#!/usr/bin/env bash
# Anvil-fork demo for the bootstrap-market deploy.
# Spins up a forked-mainnet anvil node and runs the repo's fork tests against it —
# they deploy the full mini market + EulerSwap pool and assert it works. Never broadcasts.

set -euo pipefail

: "${MAINNET_RPC_URL:?MAINNET_RPC_URL must be set. Copy .env.example to .env and source it.}"

ANVIL_PORT=${ANVIL_PORT:-8545}

cleanup() {
  if [ -n "${ANVIL_PID:-}" ]; then
    kill "$ANVIL_PID" 2>/dev/null || true
    wait "$ANVIL_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "Forking mainnet to anvil on port $ANVIL_PORT..."
anvil --fork-url "$MAINNET_RPC_URL" --port "$ANVIL_PORT" --silent &
ANVIL_PID=$!

for _ in $(seq 1 20); do
  if cast block-number --rpc-url "http://localhost:$ANVIL_PORT" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

echo "Anvil ready."
echo
echo "Running the bootstrap-market fork tests against the local anvil. This deploys"
echo "the whole mini market: ungoverned vaults, oracles, collateral matrix, paired"
echo "EulerSwap pool, and verifies a real swap moves inventory through the escrows."
echo

# Run the fork tests against the local anvil fork. Set BOTH so either test style hits it:
#   - MAINNET_RPC_URL=anvil  → tests that vm.createSelectFork(vm.envString("MAINNET_RPC_URL"))
#     fork from the ENV VAR (this repo's style); --fork-url alone is silently ignored by them
#   - --fork-url=anvil       → tests that rely on forge's default fork (no createSelectFork)
# This repo only uses the first, but setting both is robust and matches the template pattern.
MAINNET_RPC_URL="http://localhost:$ANVIL_PORT" \
  forge test \
  --match-path "test/*.fork.t.sol" \
  --fork-url "http://localhost:$ANVIL_PORT" \
  -vv

echo
echo "Demo complete. Anvil shutting down."
