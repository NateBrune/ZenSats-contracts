#!/bin/bash
set -e
source .env
forge script script/DeployWbtc.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify -vv --with-gas-price 70000000 --priority-gas-price 70000000
