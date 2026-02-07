import argparse
import asyncio
import os
import time
from collections import deque
from datetime import datetime, timezone

import plotext as plt
from dotenv import load_dotenv
from web3 import Web3

# --- Load environment variables ---
load_dotenv(os.path.join(os.path.dirname(__file__), "..", ".env"))
RPC_URL = os.getenv("MAINNET_RPC_URL")
if not RPC_URL:
    raise RuntimeError("MAINNET_RPC_URL not set in .env")

# --- Config ---
DEFAULT_POOL_ADDRESS = "0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E"
CANDLE_INTERVAL = 60  # seconds per candle
POLL_INTERVAL = 5     # seconds between live updates
HISTORY_HOURS = 4
MAX_CANDLES = HISTORY_HOURS * 60  # 1-minute candles

# --- ABI (provided by user) ---
POOL_ABI = [
    {"name": "Transfer", "inputs": [{"name": "sender", "type": "address", "indexed": True}, {"name": "receiver", "type": "address", "indexed": True}, {"name": "value", "type": "uint256", "indexed": False}], "anonymous": False, "type": "event"},
    {"name": "Approval", "inputs": [{"name": "owner", "type": "address", "indexed": True}, {"name": "spender", "type": "address", "indexed": True}, {"name": "value", "type": "uint256", "indexed": False}], "anonymous": False, "type": "event"},
    {"name": "TokenExchange", "inputs": [{"name": "buyer", "type": "address", "indexed": True}, {"name": "sold_id", "type": "int128", "indexed": False}, {"name": "tokens_sold", "type": "uint256", "indexed": False}, {"name": "bought_id", "type": "int128", "indexed": False}, {"name": "tokens_bought", "type": "uint256", "indexed": False}], "anonymous": False, "type": "event"},
    {"name": "AddLiquidity", "inputs": [{"name": "provider", "type": "address", "indexed": True}, {"name": "token_amounts", "type": "uint256[2]", "indexed": False}, {"name": "fees", "type": "uint256[2]", "indexed": False}, {"name": "invariant", "type": "uint256", "indexed": False}, {"name": "token_supply", "type": "uint256", "indexed": False}], "anonymous": False, "type": "event"},
    {"name": "RemoveLiquidity", "inputs": [{"name": "provider", "type": "address", "indexed": True}, {"name": "token_amounts", "type": "uint256[2]", "indexed": False}, {"name": "fees", "type": "uint256[2]", "indexed": False}, {"name": "token_supply", "type": "uint256", "indexed": False}], "anonymous": False, "type": "event"},
    {"name": "RemoveLiquidityOne", "inputs": [{"name": "provider", "type": "address", "indexed": True}, {"name": "token_amount", "type": "uint256", "indexed": False}, {"name": "coin_amount", "type": "uint256", "indexed": False}, {"name": "token_supply", "type": "uint256", "indexed": False}], "anonymous": False, "type": "event"},
    {"name": "RemoveLiquidityImbalance", "inputs": [{"name": "provider", "type": "address", "indexed": True}, {"name": "token_amounts", "type": "uint256[2]", "indexed": False}, {"name": "fees", "type": "uint256[2]", "indexed": False}, {"name": "invariant", "type": "uint256", "indexed": False}, {"name": "token_supply", "type": "uint256", "indexed": False}], "anonymous": False, "type": "event"},
    {"name": "RampA", "inputs": [{"name": "old_A", "type": "uint256", "indexed": False}, {"name": "new_A", "type": "uint256", "indexed": False}, {"name": "initial_time", "type": "uint256", "indexed": False}, {"name": "future_time", "type": "uint256", "indexed": False}], "anonymous": False, "type": "event"},
    {"name": "StopRampA", "inputs": [{"name": "A", "type": "uint256", "indexed": False}, {"name": "t", "type": "uint256", "indexed": False}], "anonymous": False, "type": "event"},
    {"name": "CommitNewFee", "inputs": [{"name": "new_fee", "type": "uint256", "indexed": False}], "anonymous": False, "type": "event"},
    {"name": "ApplyNewFee", "inputs": [{"name": "fee", "type": "uint256", "indexed": False}], "anonymous": False, "type": "event"},
    {"stateMutability": "nonpayable", "type": "constructor", "inputs": [], "outputs": []},
    {"stateMutability": "nonpayable", "type": "function", "name": "initialize", "inputs": [{"name": "_name", "type": "string"}, {"name": "_symbol", "type": "string"}, {"name": "_coins", "type": "address[4]"}, {"name": "_rate_multipliers", "type": "uint256[4]"}, {"name": "_A", "type": "uint256"}, {"name": "_fee", "type": "uint256"}], "outputs": []},
    {"stateMutability": "view", "type": "function", "name": "decimals", "inputs": [], "outputs": [{"name": "", "type": "uint8"}]},
    {"stateMutability": "nonpayable", "type": "function", "name": "transfer", "inputs": [{"name": "_to", "type": "address"}, {"name": "_value", "type": "uint256"}], "outputs": [{"name": "", "type": "bool"}]},
    {"stateMutability": "nonpayable", "type": "function", "name": "transferFrom", "inputs": [{"name": "_from", "type": "address"}, {"name": "_to", "type": "address"}, {"name": "_value", "type": "uint256"}], "outputs": [{"name": "", "type": "bool"}]},
    {"stateMutability": "nonpayable", "type": "function", "name": "approve", "inputs": [{"name": "_spender", "type": "address"}, {"name": "_value", "type": "uint256"}], "outputs": [{"name": "", "type": "bool"}]},
    {"stateMutability": "nonpayable", "type": "function", "name": "permit", "inputs": [{"name": "_owner", "type": "address"}, {"name": "_spender", "type": "address"}, {"name": "_value", "type": "uint256"}, {"name": "_deadline", "type": "uint256"}, {"name": "_v", "type": "uint8"}, {"name": "_r", "type": "bytes32"}, {"name": "_s", "type": "bytes32"}], "outputs": [{"name": "", "type": "bool"}]},
    {"stateMutability": "view", "type": "function", "name": "last_price", "inputs": [], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "view", "type": "function", "name": "ema_price", "inputs": [], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "view", "type": "function", "name": "get_balances", "inputs": [], "outputs": [{"name": "", "type": "uint256[2]"}]},
    {"stateMutability": "view", "type": "function", "name": "admin_fee", "inputs": [], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "view", "type": "function", "name": "A", "inputs": [], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "view", "type": "function", "name": "A_precise", "inputs": [], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "view", "type": "function", "name": "get_p", "inputs": [], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "view", "type": "function", "name": "price_oracle", "inputs": [], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "view", "type": "function", "name": "get_virtual_price", "inputs": [], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "view", "type": "function", "name": "calc_token_amount", "inputs": [{"name": "_amounts", "type": "uint256[2]"}, {"name": "_is_deposit", "type": "bool"}], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "nonpayable", "type": "function", "name": "add_liquidity", "inputs": [{"name": "_amounts", "type": "uint256[2]"}, {"name": "_min_mint_amount", "type": "uint256"}], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "nonpayable", "type": "function", "name": "add_liquidity", "inputs": [{"name": "_amounts", "type": "uint256[2]"}, {"name": "_min_mint_amount", "type": "uint256"}, {"name": "_receiver", "type": "address"}], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "view", "type": "function", "name": "get_dy", "inputs": [{"name": "i", "type": "int128"}, {"name": "j", "type": "int128"}, {"name": "dx", "type": "uint256"}], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "view", "type": "function", "name": "get_dx", "inputs": [{"name": "i", "type": "int128"}, {"name": "j", "type": "int128"}, {"name": "dy", "type": "uint256"}], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "nonpayable", "type": "function", "name": "exchange", "inputs": [{"name": "i", "type": "int128"}, {"name": "j", "type": "int128"}, {"name": "_dx", "type": "uint256"}, {"name": "_min_dy", "type": "uint256"}], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "nonpayable", "type": "function", "name": "exchange", "inputs": [{"name": "i", "type": "int128"}, {"name": "j", "type": "int128"}, {"name": "_dx", "type": "uint256"}, {"name": "_min_dy", "type": "uint256"}, {"name": "_receiver", "type": "address"}], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "nonpayable", "type": "function", "name": "remove_liquidity", "inputs": [{"name": "_burn_amount", "type": "uint256"}, {"name": "_min_amounts", "type": "uint256[2]"}], "outputs": [{"name": "", "type": "uint256[2]"}]},
    {"stateMutability": "nonpayable", "type": "function", "name": "remove_liquidity", "inputs": [{"name": "_burn_amount", "type": "uint256"}, {"name": "_min_amounts", "type": "uint256[2]"}, {"name": "_receiver", "type": "address"}], "outputs": [{"name": "", "type": "uint256[2]"}]},
    {"stateMutability": "nonpayable", "type": "function", "name": "remove_liquidity_imbalance", "inputs": [{"name": "_amounts", "type": "uint256[2]"}, {"name": "_max_burn_amount", "type": "uint256"}], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "nonpayable", "type": "function", "name": "remove_liquidity_imbalance", "inputs": [{"name": "_amounts", "type": "uint256[2]"}, {"name": "_max_burn_amount", "type": "uint256"}, {"name": "_receiver", "type": "address"}], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "view", "type": "function", "name": "calc_withdraw_one_coin", "inputs": [{"name": "_burn_amount", "type": "uint256"}, {"name": "i", "type": "int128"}], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "nonpayable", "type": "function", "name": "remove_liquidity_one_coin", "inputs": [{"name": "_burn_amount", "type": "uint256"}, {"name": "i", "type": "int128"}, {"name": "_min_received", "type": "uint256"}], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "nonpayable", "type": "function", "name": "remove_liquidity_one_coin", "inputs": [{"name": "_burn_amount", "type": "uint256"}, {"name": "i", "type": "int128"}, {"name": "_min_received", "type": "uint256"}, {"name": "_receiver", "type": "address"}], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "nonpayable", "type": "function", "name": "ramp_A", "inputs": [{"name": "_future_A", "type": "uint256"}, {"name": "_future_time", "type": "uint256"}], "outputs": []},
    {"stateMutability": "nonpayable", "type": "function", "name": "stop_ramp_A", "inputs": [], "outputs": []},
    {"stateMutability": "nonpayable", "type": "function", "name": "set_ma_exp_time", "inputs": [{"name": "_ma_exp_time", "type": "uint256"}], "outputs": []},
    {"stateMutability": "view", "type": "function", "name": "admin_balances", "inputs": [{"name": "i", "type": "uint256"}], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "nonpayable", "type": "function", "name": "commit_new_fee", "inputs": [{"name": "_new_fee", "type": "uint256"}], "outputs": []},
    {"stateMutability": "nonpayable", "type": "function", "name": "apply_new_fee", "inputs": [], "outputs": []},
    {"stateMutability": "nonpayable", "type": "function", "name": "withdraw_admin_fees", "inputs": [], "outputs": []},
    {"stateMutability": "pure", "type": "function", "name": "version", "inputs": [], "outputs": [{"name": "", "type": "string"}]},
    {"stateMutability": "view", "type": "function", "name": "factory", "inputs": [], "outputs": [{"name": "", "type": "address"}]},
    {"stateMutability": "view", "type": "function", "name": "coins", "inputs": [{"name": "arg0", "type": "uint256"}], "outputs": [{"name": "", "type": "address"}]},
    {"stateMutability": "view", "type": "function", "name": "balances", "inputs": [{"name": "arg0", "type": "uint256"}], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "view", "type": "function", "name": "fee", "inputs": [], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "view", "type": "function", "name": "future_fee", "inputs": [], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "view", "type": "function", "name": "admin_action_deadline", "inputs": [], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "view", "type": "function", "name": "initial_A", "inputs": [], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "view", "type": "function", "name": "future_A", "inputs": [], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "view", "type": "function", "name": "initial_A_time", "inputs": [], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "view", "type": "function", "name": "future_A_time", "inputs": [], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "view", "type": "function", "name": "name", "inputs": [], "outputs": [{"name": "", "type": "string"}]},
    {"stateMutability": "view", "type": "function", "name": "symbol", "inputs": [], "outputs": [{"name": "", "type": "string"}]},
    {"stateMutability": "view", "type": "function", "name": "balanceOf", "inputs": [{"name": "arg0", "type": "address"}], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "view", "type": "function", "name": "allowance", "inputs": [{"name": "arg0", "type": "address"}, {"name": "arg1", "type": "address"}], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "view", "type": "function", "name": "totalSupply", "inputs": [], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "view", "type": "function", "name": "DOMAIN_SEPARATOR", "inputs": [], "outputs": [{"name": "", "type": "bytes32"}]},
    {"stateMutability": "view", "type": "function", "name": "nonces", "inputs": [{"name": "arg0", "type": "address"}], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "view", "type": "function", "name": "ma_exp_time", "inputs": [], "outputs": [{"name": "", "type": "uint256"}]},
    {"stateMutability": "view", "type": "function", "name": "ma_last_time", "inputs": [], "outputs": [{"name": "", "type": "uint256"}]}
]

w3 = Web3(Web3.HTTPProvider(RPC_URL))
pool = None
POOL_ADDRESS = None
BASE_INDEX = 0
QUOTE_INDEX = 1
BASE_SYMBOL = "BASE"
QUOTE_SYMBOL = "QUOTE"

POOL_PRESETS = {
    "crvusd_usdc": {
        "address": "0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E",
        "base": "crvUSD",
        "quote": "USDC",
    },
    "crvusd_usdt": {
        "address": "0x390f3595bca2df7d23783dfd126427cceb997bf4",
        "base": "crvUSD",
        "quote": "USDT",
    },
    "crvusd_pyusd": {
        "address": "0x625e92624bc2d88619accc1788365a69767f6200",
        "base": "crvUSD",
        "quote": "PYUSD",
    },
    "crvusd_gho": {
        "address": "0x635ef0056a597d13863b73825cca297236578595",
        "base": "crvUSD",
        "quote": "GHO",
    },
}

ERC20_ABI = [
    {
        "name": "decimals",
        "inputs": [],
        "outputs": [{"name": "", "type": "uint8"}],
        "stateMutability": "view",
        "type": "function",
    }
]

_coin_decimals = {}
_block_time_cache = {}


class Candle:
    def __init__(self, timestamp):
        self.timestamp = timestamp
        self.open = None
        self.high = None
        self.low = None
        self.close = None
        self.volume = 0

    def update(self, price, volume):
        if price is None:
            return
        if self.open is None:
            self.open = price
        self.close = price
        self.high = price if self.high is None else max(self.high, price)
        self.low = price if self.low is None else min(self.low, price)
        self.volume += volume


candles = deque(maxlen=MAX_CANDLES)


def get_pool_price():
    try:
        raw_price = pool.functions.last_price().call()
        return raw_price / 1e18
    except Exception as exc:
        print(f"Error fetching pool price: {exc}")
        return None


def get_recent_volume(start_block, end_block):
    try:
        event = pool.events.TokenExchange()
        logs = event.get_logs(from_block=start_block, to_block=end_block)
        total_volume = sum(log["args"]["tokens_sold"] for log in logs)
        return total_volume / 1e18 if total_volume else 0
    except Exception as exc:
        print(f"Error fetching volume: {exc}")
        return 0


def get_coin_decimals(coin_index):
    if coin_index in _coin_decimals:
        return _coin_decimals[coin_index]
    coin_address = pool.functions.coins(coin_index).call()
    token = w3.eth.contract(address=coin_address, abi=ERC20_ABI)
    decimals = token.functions.decimals().call()
    _coin_decimals[coin_index] = decimals
    return decimals


def get_block_timestamp(block_number):
    if block_number in _block_time_cache:
        return _block_time_cache[block_number]
    block = w3.eth.get_block(block_number)
    _block_time_cache[block_number] = block["timestamp"]
    return block["timestamp"]


def price_from_exchange(log):
    sold_id = int(log["args"]["sold_id"])
    bought_id = int(log["args"]["bought_id"])
    tokens_sold = log["args"]["tokens_sold"]
    tokens_bought = log["args"]["tokens_bought"]

    sold_decimals = get_coin_decimals(sold_id)
    bought_decimals = get_coin_decimals(bought_id)

    sold_amt = tokens_sold / (10 ** sold_decimals)
    bought_amt = tokens_bought / (10 ** bought_decimals)

    # Price as base per quote using pool indices
    if sold_id == BASE_INDEX and bought_id == QUOTE_INDEX and bought_amt:
        return sold_amt / bought_amt
    if sold_id == QUOTE_INDEX and bought_id == BASE_INDEX and sold_amt:
        return bought_amt / sold_amt
    return None


def bootstrap_candles():
    candles.clear()
    try:
        now = int(time.time())
        window_seconds = HISTORY_HOURS * 3600
        window_start = now - window_seconds
        current_block = w3.eth.block_number
        avg_block_time = 12
        blocks_back = int(window_seconds / avg_block_time)
        start_block = max(0, current_block - blocks_back)
        end_block = current_block

        event = pool.events.TokenExchange()
        logs = []
        chunk = 100
        b_start = start_block
        while b_start <= end_block:
            b_end = min(b_start + chunk - 1, end_block)
            try:
                logs += event.get_logs(from_block=b_start, to_block=b_end)
            except Exception as exc:
                print(f"Error fetching bootstrap events: {exc}, skipping chunk {b_start}-{b_end}")
            b_start += chunk

        minute_buckets = {}
        for log in logs:
            ts = get_block_timestamp(log["blockNumber"])
            minute = ts - (ts % 60)
            price = price_from_exchange(log)
            if minute not in minute_buckets:
                minute_buckets[minute] = {"open": None, "high": None, "low": None, "close": None, "volume": 0}
            bucket = minute_buckets[minute]
            if price is not None:
                if bucket["open"] is None:
                    bucket["open"] = price
                bucket["close"] = price
                bucket["high"] = price if bucket["high"] is None else max(bucket["high"], price)
                bucket["low"] = price if bucket["low"] is None else min(bucket["low"], price)
            bucket["volume"] += log["args"]["tokens_sold"] / 1e18

        times = list(range(window_start - (window_start % 60), now, 60))
        last_close = None
        for t in times:
            c = Candle(datetime.fromtimestamp(t, tz=timezone.utc))
            bucket = minute_buckets.get(t)
            if bucket and bucket["open"] is not None:
                c.open = bucket["open"]
                c.high = bucket["high"]
                c.low = bucket["low"]
                c.close = bucket["close"]
                c.volume = bucket["volume"]
                last_close = c.close
            else:
                c.open = c.high = c.low = c.close = last_close
                c.volume = 0
            candles.append(c)
    except Exception as exc:
        print(f"Bootstrap failed: {exc}. Starting with empty candles.")


def update_candles(price, volume):
    now = datetime.now(timezone.utc)
    if not candles or (now - candles[-1].timestamp).total_seconds() > CANDLE_INTERVAL:
        candles.append(Candle(now))
    candles[-1].update(price, volume)


def draw_chart():
    plt.clf()
    if not candles:
        print("No data yet.")
        return

    # Build candlestick inputs expected by plotext 5.3.2
    valid = [c for c in candles if c.open is not None and c.high is not None and c.low is not None and c.close is not None]
    if not valid:
        print("No candle data yet.")
        return

    dates = [c.timestamp.strftime("%d/%m/%Y %H:%M") for c in valid]
    data = {
        "Open": [c.open for c in valid],
        "Close": [c.close for c in valid],
        "High": [c.high for c in valid],
        "Low": [c.low for c in valid],
    }

    ymin = min(data["Low"])
    ymax = max(data["High"])
    padding = max((ymax - ymin) * 0.1, 0.001)

    plt.date_form("d/m/Y H:M")
    plt.candlestick(dates, data)
    plt.title(f"Curve TwoCrypto Candles (1m) - {BASE_SYMBOL}/{QUOTE_SYMBOL}")
    plt.xlabel("Time (UTC)")
    plt.ylabel("Price")
    plt.ylim(ymin - padding, ymax + padding)
    plt.show()


def parse_args():
    parser = argparse.ArgumentParser(description="Live candle chart for Curve TwoCrypto pools.")
    parser.add_argument("--pool", choices=sorted(POOL_PRESETS.keys()), help="Known pool preset")
    parser.add_argument("--pool-address", default=DEFAULT_POOL_ADDRESS, help="Curve pool address (overrides --pool)")
    parser.add_argument("--base-index", type=int, default=0, help="Base coin index (default: 0)")
    parser.add_argument("--quote-index", type=int, default=1, help="Quote coin index (default: 1)")
    parser.add_argument("--history-hours", type=int, default=HISTORY_HOURS, help="Hours of bootstrap history (default: 4)")
    return parser.parse_args()


def init_pool(args):
    global POOL_ADDRESS, pool, BASE_INDEX, QUOTE_INDEX, BASE_SYMBOL, QUOTE_SYMBOL
    global HISTORY_HOURS, MAX_CANDLES
    if args.pool:
        preset = POOL_PRESETS[args.pool]
        POOL_ADDRESS = Web3.to_checksum_address(preset["address"])
        BASE_SYMBOL = preset["base"]
        QUOTE_SYMBOL = preset["quote"]
    else:
        POOL_ADDRESS = Web3.to_checksum_address(args.pool_address)
        BASE_SYMBOL = f"INDEX{args.base_index}"
        QUOTE_SYMBOL = f"INDEX{args.quote_index}"
    pool = w3.eth.contract(address=POOL_ADDRESS, abi=POOL_ABI)
    BASE_INDEX = args.base_index
    QUOTE_INDEX = args.quote_index
    HISTORY_HOURS = max(1, int(args.history_hours))
    MAX_CANDLES = HISTORY_HOURS * 60


async def main():
    print(f"Bootstrapping last {HISTORY_HOURS} hours of candles...")
    bootstrap_candles()
    print(f"Bootstrap complete. Candles: {len(candles)}")
    draw_chart()
    print("Listening for swaps on pool... Press Ctrl+C to exit.")
    last_draw = datetime.now(timezone.utc)
    last_seen_block = w3.eth.block_number

    while True:
        current_block = w3.eth.block_number
        if current_block > last_seen_block:
            event = pool.events.TokenExchange()
            logs = event.get_logs(from_block=last_seen_block + 1, to_block=current_block)
            last_seen_block = current_block
            for log in logs:
                price = price_from_exchange(log)
                volume = log["args"]["tokens_sold"] / 1e18
                ts = get_block_timestamp(log["blockNumber"])
                candle_time = datetime.fromtimestamp(ts - (ts % 60), tz=timezone.utc)
                if not candles or candles[-1].timestamp != candle_time:
                    candles.append(Candle(candle_time))
                candles[-1].update(price, volume)
        else:
            pass
        now = datetime.now(timezone.utc)
        if (now - last_draw).total_seconds() > 5:
            draw_chart()
            last_draw = now

        await asyncio.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    try:
        args = parse_args()
        init_pool(args)
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nExiting.")