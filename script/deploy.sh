#!/bin/bash

# SiloBooster Deployment Script
#
# Two deployment approaches:
#   A) Step-by-step: Deploy vault, then strategy, then link them
#   B) All-in-one: Deploy everything in one transaction
#
# Usage:
#   ./script/deploy.sh vault [owner]                    - Step 1: Deploy vault (no strategy)
#   ./script/deploy.sh strategy-ipor <vault>            - Step 2a: Deploy IPOR strategy
#   ./script/deploy.sh strategy-tokemak <vault>         - Step 2b: Deploy Tokemak strategy
#   ./script/deploy.sh set-strategy <vault> <strategy>  - Step 3: Link strategy to vault
#
#   ./script/deploy.sh all-ipor [owner]                 - All-in-one with IPOR
#   ./script/deploy.sh all-tokemak [owner]              - All-in-one with Tokemak

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Load .env
if [ -f .env ]; then
    source .env
fi

check_env() {
    if [ -z "$PRIVATE_KEY" ]; then
        echo -e "${RED}Error: PRIVATE_KEY not set in .env${NC}"
        exit 1
    fi
    if [ -z "$MAINNET_RPC_URL" ]; then
        echo -e "${RED}Error: MAINNET_RPC_URL not set in .env${NC}"
        exit 1
    fi
}

get_owner() {
    local owner="$1"
    if [ -z "$owner" ]; then
        owner=$(cast wallet address "$PRIVATE_KEY" 2>/dev/null || echo "")
        if [ -z "$owner" ]; then
            echo -e "${RED}Error: Could not derive address from private key${NC}"
            exit 1
        fi
        echo -e "${YELLOW}Using deployer as owner: $owner${NC}"
    fi
    echo "$owner"
}

# Check if --broadcast flag is present
is_broadcast() {
    for arg in "$@"; do
        if [ "$arg" == "--broadcast" ]; then
            return 0
        fi
    done
    return 1
}

run_script() {
    local func="$1"
    local args="$2"
    local broadcast=""
    local verify=""

    if is_broadcast "$@"; then
        broadcast="--broadcast"
        if [ -n "$ETHERSCAN_API_KEY" ]; then
            verify="--verify --etherscan-api-key $ETHERSCAN_API_KEY"
        fi
        echo -e "${GREEN}Broadcasting transaction...${NC}"
    else
        echo -e "${YELLOW}DRY RUN (add --broadcast to deploy)${NC}"
    fi

    forge script script/Deploy.s.sol:Deploy \
        --sig "$func" \
        $args \
        --rpc-url "$MAINNET_RPC_URL" \
        --private-key "$PRIVATE_KEY" \
        $broadcast \
        $verify \
        -vvv
}

main() {
    local cmd="$1"
    shift || true

    case "$cmd" in
        # Step-by-step deployment
        vault)
            check_env
            local owner=$(get_owner "$1")
            echo -e "${BLUE}=== Deploying Vault (without strategy) ===${NC}"
            run_script "deployVault(address)" "$owner" "$@"
            ;;

        strategy-ipor)
            check_env
            local vault="$1"
            if [ -z "$vault" ]; then
                echo -e "${RED}Error: Vault address required${NC}"
                echo "Usage: ./script/deploy.sh strategy-ipor <vault_address> [--broadcast]"
                exit 1
            fi
            echo -e "${BLUE}=== Deploying IPOR Strategy ===${NC}"
            run_script "deployIporStrategy(address)" "$vault" "$@"
            ;;

        strategy-tokemak)
            check_env
            local vault="$1"
            if [ -z "$vault" ]; then
                echo -e "${RED}Error: Vault address required${NC}"
                echo "Usage: ./script/deploy.sh strategy-tokemak <vault_address> [--broadcast]"
                exit 1
            fi
            echo -e "${BLUE}=== Deploying Tokemak Strategy ===${NC}"
            run_script "deployTokemakStrategy(address)" "$vault" "$@"
            ;;

        set-strategy)
            check_env
            local vault="$1"
            local strategy="$2"
            if [ -z "$vault" ] || [ -z "$strategy" ]; then
                echo -e "${RED}Error: Vault and strategy addresses required${NC}"
                echo "Usage: ./script/deploy.sh set-strategy <vault> <strategy> [--broadcast]"
                exit 1
            fi
            echo -e "${BLUE}=== Setting Initial Strategy ===${NC}"
            run_script "setInitialStrategy(address,address)" "$vault $strategy" "$@"
            ;;

        # All-in-one deployment
        all-ipor)
            check_env
            local owner=$(get_owner "$1")
            echo -e "${BLUE}=== Deploying All with IPOR Strategy ===${NC}"
            run_script "deployAllWithIpor(address)" "$owner" "$@"
            ;;

        all-tokemak)
            check_env
            local owner=$(get_owner "$1")
            echo -e "${BLUE}=== Deploying All with Tokemak Strategy ===${NC}"
            run_script "deployAllWithTokemak(address)" "$owner" "$@"
            ;;

        *)
            cat << 'EOF'
SiloBooster Deployment Script

STEP-BY-STEP DEPLOYMENT (recommended for understanding):
  ./script/deploy.sh vault [owner] [--broadcast]
      Deploy vault without strategy

  ./script/deploy.sh strategy-ipor <vault> [--broadcast]
      Deploy IPOR strategy for a vault

  ./script/deploy.sh strategy-tokemak <vault> [--broadcast]
      Deploy Tokemak strategy for a vault

  ./script/deploy.sh set-strategy <vault> <strategy> [--broadcast]
      Set the initial strategy on the vault

ALL-IN-ONE DEPLOYMENT (single transaction):
  ./script/deploy.sh all-ipor [owner] [--broadcast]
      Deploy vault + IPOR strategy + tracker

  ./script/deploy.sh all-tokemak [owner] [--broadcast]
      Deploy vault + Tokemak strategy + tracker

OPTIONS:
  --broadcast    Actually send transactions (default is dry run)
  [owner]        Owner address (defaults to deployer)

ENVIRONMENT VARIABLES (.env):
  PRIVATE_KEY        Deployer private key (required)
  MAINNET_RPC_URL    Ethereum RPC URL (required)
  ETHERSCAN_API_KEY  For contract verification (optional)

EXAMPLES:
  # Dry run all-in-one deployment
  ./script/deploy.sh all-ipor

  # Deploy for real with custom owner
  ./script/deploy.sh all-tokemak 0xOwnerAddress --broadcast

  # Step-by-step deployment
  ./script/deploy.sh vault --broadcast
  # Note the vault address from output, then:
  ./script/deploy.sh strategy-ipor 0xVaultAddress --broadcast
  # Note the strategy address from output, then:
  ./script/deploy.sh set-strategy 0xVaultAddress 0xStrategyAddress --broadcast
EOF
            ;;
    esac
}

main "$@"
