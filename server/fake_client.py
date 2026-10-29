#!/usr/bin/env python3
"""Minimal client that pretends to be a joining game, for debugging the host without booting one.

    python fake_client.py --port 7496 [--company new]

Connects to the relay, claims the client role, asks for the world, then prints every message it
receives (type, size). Used to find out how far the host gets through the world transfer.
"""
import argparse
import json
import socket
import sys
import time

PREFIX = 8


def frame(message):
    body = json.dumps(message, separators=(",", ":")).encode("utf-8")
    return f"{len(body):0{PREFIX}d}".encode("ascii") + body


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--company", default="new")
    parser.add_argument("--seconds", type=float, default=40.0)
    args = parser.parse_args(argv)

    sock = socket.create_connection((args.host, args.port), timeout=10)
    sock.sendall(frame({"t": "role", "role": "client", "player": "fake", "name": "fake"}))
    sock.sendall(frame({"t": "join_request", "player": "fake"}))
    print("sent role + join_request", flush=True)

    buffer = b""
    deadline = time.time() + args.seconds
    counts = {}
    total = 0
    while time.time() < deadline:
        sock.settimeout(max(0.1, deadline - time.time()))
        try:
            chunk = sock.recv(1 << 20)
        except socket.timeout:
            break
        if not chunk:
            print("server closed the connection", flush=True)
            break
        buffer += chunk
        while len(buffer) >= PREFIX:
            length = int(buffer[:PREFIX])
            if len(buffer) < PREFIX + length:
                break
            body = buffer[PREFIX:PREFIX + length]
            buffer = buffer[PREFIX + length:]
            total += length
            try:
                message = json.loads(body.decode("utf-8"))
                kind = message.get("t", "?")
            except Exception:  # noqa: BLE001
                kind = "unparsable"
            counts[kind] = counts.get(kind, 0) + 1
            if counts[kind] <= 3 or kind not in ("world_part", "clock"):
                print(f"  {kind} {length} bytes", flush=True)
        if counts.get("world_end"):
            print("world_end received", flush=True)
            break

    print(f"totals: {counts}, {total} bytes", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
