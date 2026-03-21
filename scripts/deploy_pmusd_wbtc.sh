#!/bin/bash
set -e
source .env
forge script script/DeployPmUsdWbtc.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify -vv --with-gas-price 50000000 --priority-gas-price 50000000
