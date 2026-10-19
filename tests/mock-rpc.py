#!/usr/bin/env python3
"""Test-only JSON-RPC proxy for the self-host installer end-to-end test.

Forwards every call to a real upstream RPC (the testnet), except a few read
calls it answers itself so the test can play a license holder without owning
a license:

  NFT.balanceOf(owner, 1)          -> --licenses
  NodeCheckIn.findOpenSlots(owner) -> --open-slots, minus the bound slot
  NodeCheckIn.nodeToOwner(node)    -> owner, once <state-dir>/bound-node holds node
  NodeCheckIn.nodeToSlot(node)     -> --bound-slot, for that bound node
  eth_getBalance(bound node)       -> <state-dir>/balance-wei, if that file exists

With --emulate-node-to-slot it also answers nodeToSlot(node) for unbound
nodes (0, the mapping default). The mainnet NodeCheckIn implementation has
that getter, but the testnet deployment at the time of writing does not: a
real nodeToSlot call there reverts for every node, which makes
`salvorias-node slot-info --node` fail on testnet. The flag lets the installer's
flow be tested on testnet the way it behaves on mainnet.

It refuses eth_sendRawTransaction and eth_sendTransaction outright and logs
the attempt, so nothing run against it can ever send a transaction.

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
BLOCKED_METHODS = {"eth_sendRawTransaction", "eth_sendTransaction"}

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


class Mock:
    def __init__(self, opts):
        self.o = opts
        self.checkin = opts.checkin.lower()
        self.nft = opts.nft.lower()
        self.owner = opts.owner.lower()
        self.slots = [int(s) for s in opts.open_slots.split(",") if s != ""]

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
            self.log(f"BLOCKED {method}")
            return {"jsonrpc": "2.0", "id": rid,
                    "error": {"code": -32000, "message": "mock-rpc: transactions are disabled in this test"}}

        bound = (self.state("bound-node") or "").lower() or None
        result = None
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
            elif to == self.checkin and sel == SEL_NODE_TO_SLOT and bound and arg_address(data, 0) == bound:
                result = enc_uint(self.o.bound_slot)
            elif to == self.checkin and sel == SEL_NODE_TO_SLOT and self.o.emulate_node_to_slot:
                result = enc_uint(0)
        elif method == "eth_getBalance" and params and bound and str(params[0]).lower() == bound:
            balance = self.state("balance-wei")
            if balance is not None:
                result = hex(int(balance))

        if result is not None:
            self.log(f"MOCKED {method} {sel if method == 'eth_call' else ''}".rstrip())
            return {"jsonrpc": "2.0", "id": rid, "result": result}
        resp = self.forward(req)
        if isinstance(resp, dict) and resp.get("error"):
            detail = ""
            if method == "eth_call" and params:
                call = params[0] or {}
                detail = f" to={call.get('to')} sel={(call.get('data') or call.get('input') or '')[:10]}"
            self.log(f"UPSTREAM-ERROR {method}{detail}: {resp['error'].get('message')}")
        return resp


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
