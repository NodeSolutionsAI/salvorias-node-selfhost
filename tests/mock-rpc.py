#!/usr/bin/env python3
"""Test-only JSON-RPC proxy for the self-host installer end-to-end test.

Forwards every call to a real upstream RPC (the testnet), except a few read
calls it answers itself so the test can play a license holder without owning
a license:

  NFT.balanceOf(owner, 1)          -> --licenses
  NodeCheckIn.findOpenSlots(owner) -> --open-slots, minus the bound slot
  NodeCheckIn.nodeToOwner(node)    -> owner, once <state-dir>/bound-node holds node
  NodeCheckIn.nodeAddressOf(owner, i) -> the bound node at --bound-slot, else
                                     the zero address (the slot-info scan path)
  eth_getBalance(bound node)       -> <state-dir>/balance-wei, if that file exists;
                                     also for the address in <state-dir>/funded-node,
                                     so a node can be funded before it is registered
  NodeCheckIn.isNodeQualified(key, node) -> true, while <state-dir>/qualified exists

<state-dir>/replaced-by plays the app putting another node on the bound
node's license: nodeAddressOf(owner, --bound-slot) then answers that address,
while nodeToOwner keeps naming the owner for the bound node (a reverse mapping
left behind). slot-info's nodeAddressOf scan then reports boundSlot null.
  eth_gasPrice, eth_maxPriorityFeePerGas -> --fee-wei, if given

--fee-wei pins a non-zero fee, so the funding text and the daemon's
network-mode fee fields are exercised whatever the testnet fee is that day.

With --emulate-node-to-slot it also answers nodeToSlot(node): --bound-slot for
the bound node, 0 (the mapping default) for any other. That is how the mainnet
NodeCheckIn behaves. The testnet deployment has no nodeToSlot getter: a real
call reverts for every node, and salvorias-node 0.0.9+ then finds the slot by
scanning nodeAddressOf (slot-info reports "boundSlotSource":"scan"). Without
the flag this mock is faithful to testnet: nodeToSlot goes upstream and
reverts, and the mock answers the nodeAddressOf scan.

It never forwards eth_sendRawTransaction or eth_sendTransaction, so nothing
run against it can ever send a transaction. By default it refuses them and
logs the attempt (BLOCKED). A refused raw transaction is decoded first and its
fee fields are logged (never the signature), so the test can check what the
daemon tried to send. Two state files change the answer, still without
forwarding anything:
  <state-dir>/send-error    refuse with this file's text as the error message
                            (to play the chain's own refusals)
  <state-dir>/accept-sends  answer with the transaction's real hash and serve a
                            successful receipt for it, so the daemon logs a
                            confirmed check-in (logged as ACCEPTED-NOT-FORWARDED)

Usage:
  mock-rpc.py --listen 127.0.0.1:8545 --upstream https://testnet.salvorias.net \
    --checkin 0x... --nft 0x... --owner 0x... --licenses 2 --open-slots 0,1 \
    --bound-slot 1 --state-dir /tmp/mockrpc
"""

import argparse
import json
import os
import sys
import threading
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SEL_BALANCE_OF = "0x00fdd58e"      # balanceOf(address,uint256)
SEL_FIND_OPEN_SLOTS = "0x79006210"  # findOpenSlots(address,uint256)
SEL_NODE_TO_OWNER = "0x40d5a7a7"    # nodeToOwner(address)
SEL_NODE_TO_SLOT = "0x1b0eae60"     # nodeToSlot(address)
SEL_NODE_ADDRESS_OF = "0x4fb1f363"  # nodeAddressOf(address,uint256)
BLOCKED_METHODS = {"eth_sendRawTransaction", "eth_sendTransaction"}

# Keccak-256 as Ethereum uses it (the original Keccak padding, not SHA3-256's).
# Python's hashlib has only SHA3, and ethers checks the hash a node returns for
# a sent transaction against its own, so the accept mode needs the real one.
_KECCAK_RC = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]
_KECCAK_ROT = [
    [0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61],
    [28, 55, 25, 21, 56], [27, 20, 39, 8, 14],
]
_M64 = (1 << 64) - 1


def _rol(v, n):
    return ((v << n) | (v >> (64 - n))) & _M64 if n else v


def _keccak_f(a):
    for rc in _KECCAK_RC:
        c = [a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4] for x in range(5)]
        d = [c[(x - 1) % 5] ^ _rol(c[(x + 1) % 5], 1) for x in range(5)]
        a = [[a[x][y] ^ d[x] for y in range(5)] for x in range(5)]
        b = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                b[y][(2 * x + 3 * y) % 5] = _rol(a[x][y], _KECCAK_ROT[x][y])
        a = [[b[x][y] ^ ((~b[(x + 1) % 5][y]) & b[(x + 2) % 5][y]) for y in range(5)] for x in range(5)]
        a[0][0] ^= rc
    return a


def keccak256(data):
    rate = 136
    msg = bytearray(data) + b"\x01"
    while len(msg) % rate:
        msg.append(0)
    msg[-1] |= 0x80
    a = [[0] * 5 for _ in range(5)]
    for off in range(0, len(msg), rate):
        block = msg[off:off + rate]
        for i in range(rate // 8):
            x, y = i % 5, i // 5
            a[x][y] ^= int.from_bytes(block[8 * i:8 * i + 8], "little")
        a = _keccak_f(a)
    out = b"".join(a[i % 5][i // 5].to_bytes(8, "little") for i in range(4))
    return out


def selector(signature):
    return "0x" + keccak256(signature.encode()).hex()[:8]


SEL_IS_NODE_QUALIFIED = selector("isNodeQualified(uint256,address)")

LOCK = threading.Lock()


def word(n):
    return format(n, "064x")


def enc_address(addr):
    return "0x" + "0" * 24 + addr.lower()[2:]


def enc_uint(n):
    return "0x" + word(n)


def enc_uint_array(items):
    return "0x" + word(32) + word(len(items)) + "".join(word(i) for i in items)


def arg_address(data, index):
    start = 10 + 64 * index
    return "0x" + data[start + 24:start + 64].lower()


def arg_uint(data, index):
    start = 10 + 64 * index
    return int(data[start:start + 64] or "0", 16)


def rlp_decode(buf, pos=0):
    """Decodes one RLP item at pos. Returns (item, next_pos); lists are lists."""
    b = buf[pos]
    if b < 0x80:
        return buf[pos:pos + 1], pos + 1
    if b < 0xb8:
        n = b - 0x80
        return buf[pos + 1:pos + 1 + n], pos + 1 + n
    if b < 0xc0:
        ll = b - 0xb7
        n = int.from_bytes(buf[pos + 1:pos + 1 + ll], "big")
        start = pos + 1 + ll
        return buf[start:start + n], start + n
    if b < 0xf8:
        n, start = b - 0xc0, pos + 1
    else:
        ll = b - 0xf7
        n = int.from_bytes(buf[pos + 1:pos + 1 + ll], "big")
        start = pos + 1 + ll
    items, p = [], start
    while p < start + n:
        item, p = rlp_decode(buf, p)
        items.append(item)
    return items, start + n


def describe_raw_tx(raw):
    """Summarises a signed raw tx: type, chain, fee fields, gas, target, selector."""
    buf = bytes.fromhex(raw[2:] if raw.startswith("0x") else raw)
    num = lambda v: int.from_bytes(v, "big")
    if buf and buf[0] == 0x02:
        f, _ = rlp_decode(buf, 1)
        fields = {"type": 2, "chainId": num(f[0]), "nonce": num(f[1]),
                  "maxPriorityFeePerGas": num(f[2]), "maxFeePerGas": num(f[3]),
                  "gasLimit": num(f[4]), "to": "0x" + f[5].hex(), "data": f[7]}
    elif buf and buf[0] >= 0xc0:
        f, _ = rlp_decode(buf, 0)
        v = num(f[6])
        # EIP-155: v = chainId * 2 + 35 or 36; 27/28 means no chain id.
        chain = (v - 35) // 2 if v >= 35 else "none"
        fields = {"type": 0, "chainId": chain, "nonce": num(f[0]), "gasPrice": num(f[1]),
                  "gasLimit": num(f[2]), "to": "0x" + f[3].hex(), "data": f[5]}
    else:
        return f"type=unknown(0x{buf[:1].hex()})"
    data = fields.pop("data")
    fields["selector"] = "0x" + data[:4].hex()
    return " ".join(f"{k}={v}" for k, v in fields.items())


class Mock:
    def __init__(self, opts):
        self.o = opts
        self.checkin = opts.checkin.lower()
        self.nft = opts.nft.lower()
        self.owner = opts.owner.lower()
        self.slots = [int(s) for s in opts.open_slots.split(",") if s != ""]
        # Receipts for transactions taken in accept mode, by hash.
        self.receipts = {}

    def state(self, name):
        path = os.path.join(self.o.state_dir, name)
        try:
            with open(path) as fh:
                return fh.read().strip()
        except FileNotFoundError:
            return None

    def log(self, msg):
        with LOCK:
            with open(self.o.log, "a") as fh:
                fh.write(msg + "\n")

    def forward(self, req):
        body = json.dumps(req).encode()
        r = urllib.request.Request(self.o.upstream, data=body,
                                   headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(r, timeout=20) as resp:
            return json.loads(resp.read())

    def answer(self, req):
        method = req.get("method")
        rid = req.get("id")
        params = req.get("params") or []
        if method in BLOCKED_METHODS:
            detail = ""
            if method == "eth_sendRawTransaction" and params:
                try:
                    detail = " " + describe_raw_tx(str(params[0]))
                except Exception as err:  # still block, even if it cannot be decoded
                    detail = f" undecodable ({err})"
            if method == "eth_sendRawTransaction" and params and self.state("accept-sends") is not None:
                return self.accept(rid, str(params[0]), detail)
            message = self.state("send-error") or "mock-rpc: transactions are disabled in this test"
            self.log(f"BLOCKED {method}{detail}")
            return {"jsonrpc": "2.0", "id": rid, "error": {"code": -32000, "message": message}}
        if method == "eth_getTransactionReceipt" and params and str(params[0]).lower() in self.receipts:
            self.log("MOCKED eth_getTransactionReceipt")
            return {"jsonrpc": "2.0", "id": rid, "result": self.receipts[str(params[0]).lower()]}

        bound = (self.state("bound-node") or "").lower() or None
        result = None
        data = ""
        if method == "eth_call" and params:
            call = params[0] or {}
            to = (call.get("to") or "").lower()
            data = (call.get("data") or call.get("input") or "").lower()
            sel = data[:10]
            if to == self.nft and sel == SEL_BALANCE_OF and arg_address(data, 0) == self.owner:
                result = enc_uint(self.o.licenses)
            elif to == self.checkin and sel == SEL_FIND_OPEN_SLOTS and arg_address(data, 0) == self.owner:
                slots = [s for s in self.slots if not (bound and s == self.o.bound_slot)]
                result = enc_uint_array(slots)
            elif to == self.checkin and sel == SEL_NODE_TO_OWNER and bound and arg_address(data, 0) == bound:
                result = enc_address(self.owner)
            elif to == self.checkin and sel == SEL_NODE_TO_SLOT and self.o.emulate_node_to_slot:
                # Without the flag the call goes upstream and reverts, as on testnet.
                result = enc_uint(self.o.bound_slot if bound and arg_address(data, 0) == bound else 0)
            elif to == self.checkin and sel == SEL_NODE_ADDRESS_OF and arg_address(data, 0) == self.owner:
                slot = arg_uint(data, 1)
                node = bound if bound and slot == self.o.bound_slot else "0x" + "0" * 40
                replaced_by = self.state("replaced-by")
                if replaced_by and slot == self.o.bound_slot:
                    node = replaced_by.lower()
                result = enc_address(node)
            elif to == self.checkin and sel == SEL_IS_NODE_QUALIFIED and self.state("qualified") is not None:
                result = enc_uint(1)
        elif method in ("eth_gasPrice", "eth_maxPriorityFeePerGas") and self.o.fee_wei is not None:
            result = hex(self.o.fee_wei)
        elif method == "eth_getBalance" and params and str(params[0]).lower() in (
                bound, (self.state("funded-node") or "").lower() or None):
            balance = self.state("balance-wei")
            if balance is not None:
                result = hex(int(balance))

        if result is not None:
            sel_note = data[:10] if method == "eth_call" else ""
            self.log(f"MOCKED {method} {sel_note}".rstrip())
            return {"jsonrpc": "2.0", "id": rid, "result": result}
        resp = self.forward(req)
        if isinstance(resp, dict) and resp.get("error"):
            detail = ""
            if method == "eth_call" and params:
                call = params[0] or {}
                detail = f" to={call.get('to')} sel={(call.get('data') or call.get('input') or '')[:10]}"
            self.log(f"UPSTREAM-ERROR {method}{detail}: {resp['error'].get('message')}")
        return resp


    def accept(self, rid, raw, detail):
        """Takes a raw transaction without forwarding it: answers its real hash
        and keeps a successful receipt for it, in the latest upstream block."""
        buf = bytes.fromhex(raw[2:] if raw.startswith("0x") else raw)
        tx_hash = "0x" + keccak256(buf).hex()
        block = self.forward({"jsonrpc": "2.0", "id": 1, "method": "eth_blockNumber", "params": []})["result"]
        to = None
        try:
            fields = describe_raw_tx(raw).split()
            to = next(f.split("=", 1)[1] for f in fields if f.startswith("to="))
        except Exception:
            pass
        self.receipts[tx_hash] = {
            "transactionHash": tx_hash, "transactionIndex": "0x0",
            "blockHash": "0x" + keccak256(tx_hash.encode()).hex(), "blockNumber": block,
            "from": self.state("bound-node") or "0x" + "0" * 40, "to": to,
            "contractAddress": None, "cumulativeGasUsed": "0xc350", "gasUsed": "0xc350",
            "effectiveGasPrice": hex(self.o.fee_wei or 1), "logs": [],
            "logsBloom": "0x" + "00" * 256, "type": "0x2" if buf[:1] == b"\x02" else "0x0",
            "status": "0x1",
        }
        self.log(f"ACCEPTED-NOT-FORWARDED eth_sendRawTransaction{detail} hash={tx_hash}")
        return {"jsonrpc": "2.0", "id": rid, "result": tx_hash}


def make_handler(mock):
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            try:
                req = json.loads(self.rfile.read(length))
                if isinstance(req, list):
                    resp = [mock.answer(r) for r in req]
                else:
                    resp = mock.answer(req)
                body = json.dumps(resp).encode()
                self.send_response(200)
            except Exception as err:  # surface upstream failures as RPC errors
                body = json.dumps({"jsonrpc": "2.0", "id": None,
                                   "error": {"code": -32603, "message": f"mock-rpc: {err}"}}).encode()
                self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    return Handler


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--listen", default="127.0.0.1:8545")
    p.add_argument("--upstream", required=True)
    p.add_argument("--checkin", required=True)
    p.add_argument("--nft", required=True)
    p.add_argument("--owner", required=True)
    p.add_argument("--licenses", type=int, default=2)
    p.add_argument("--open-slots", default="0,1")
    p.add_argument("--bound-slot", type=int, default=1)
    p.add_argument("--state-dir", required=True)
    p.add_argument("--log", default=None)
    p.add_argument("--fee-wei", type=int, default=None,
                   help="answer eth_gasPrice and eth_maxPriorityFeePerGas with this fee")
    p.add_argument("--emulate-node-to-slot", action="store_true",
                   help="answer nodeToSlot for unbound nodes too (testnet lacks the getter)")
    opts = p.parse_args()
    os.makedirs(opts.state_dir, exist_ok=True)
    opts.log = opts.log or os.path.join(opts.state_dir, "mock-rpc.log")
    host, port = opts.listen.rsplit(":", 1)
    server = ThreadingHTTPServer((host, int(port)), make_handler(Mock(opts)))
    print(f"mock-rpc listening on {opts.listen} -> {opts.upstream}", file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
