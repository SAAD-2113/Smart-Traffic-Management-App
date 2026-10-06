#!/usr/bin/env python3
"""Test WebSocket server that imitates the ESP32 intersection controller (protocol v2).

Use it to try the app's Hardware mode without the hardware: run it on a laptop, connect the
phone to the same Wi-Fi, and in the app (Hardware Prototype -> settings) enter the laptop's IP
address and the port below. Only the Python standard library is needed.

    python tools/hardware_test_server.py                      # the example frame, every 500 ms
    python tools/hardware_test_server.py --scenario jump      # remaining_ms 5000 -> 12000 jumps
    python tools/hardware_test_server.py --scenario missing   # frames with fields missing
    python tools/hardware_test_server.py --scenario emergency # ev_request events + preemption
    python tools/hardware_test_server.py --scenario fallback  # V2I lost, fixed-time fallback
    python tools/hardware_test_server.py --scenario version   # frames with "v": 3 (unsupported)
    python tools/hardware_test_server.py --scenario restart   # uptime goes back (restart)
    python tools/hardware_test_server.py --port 81            # the ESP32's port (default 8765)

The server only sends. Anything a client sends is read and ignored (the app sends nothing).
On Windows, allow Python through the firewall when asked (private networks).
"""
from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import json
import socket
import struct
import threading
import time

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

# The example state frame from the hardware specification, unchanged.
EXAMPLE_STATE = {
    "v": 2, "type": "state", "id": "I01", "seq": 1532, "uptime_ms": 765000,
    "mode": "adaptive",
    "ctrl": "normal",
    "phase": "NS",
    "interval": "green",
    "signals": {"N": "G", "S": "G", "E": "R", "W": "R"},
    "timing": {"target_s": 22, "elapsed_ms": 9020, "remaining_ms": 12980,
               "next_phase": "EW", "reason": "NS demand 4 veh -> 22 s"},
    "plan": {"NS": {"g": 22, "y": 3, "ar": 2, "r": 19},
             "EW": {"g": 14, "y": 3, "ar": 2, "r": 27}},
    "approaches": {
        "N": {"queued": 3, "approaching": 1, "level": "high", "ev": False},
        "S": {"queued": 1, "approaching": 0, "level": "low", "ev": False},
        "E": {"queued": 1, "approaching": 0, "level": "low", "ev": False},
        "W": {"queued": 0, "approaching": 0, "level": "free", "ev": False},
    },
    "vehicles": [
        {"id": "V01", "type": "normal", "app": "N", "state": "queued", "dist_m": 12.4, "spd": 0.0, "eta_s": 0},
    ],
    "demand": {"NS": 4, "EW": 1},
    "total_vehicles": 6,
    "congestion": "high",
    "preempt": {"active": False, "approach": None, "vehicle_id": None, "status": "none"},
    "v2i": {"link": "ok", "active_vehicles": 6, "pkts_per_s": 6.0, "last_pkt_ms_ago": 180, "rejected": 0},
    "health": {"clients": 1, "heap": 182000, "fw": "1.0.0"},
}


class Scenario:
    """Produces the frames to send, one call every 500 ms."""

    def __init__(self, name: str) -> None:
        self.name = name
        self.tick = 0
        self.seq = EXAMPLE_STATE["seq"]
        self.uptime = EXAMPLE_STATE["uptime_ms"]

    def _state(self) -> dict:
        s = copy.deepcopy(EXAMPLE_STATE)
        if self.name != "example":
            self.seq += 1
            self.uptime += 500
            s["seq"], s["uptime_ms"] = self.seq, self.uptime
        return s

    def _event(self, event: str, detail: str) -> dict:
        self.seq += 1
        return {"v": 2, "type": "event", "seq": self.seq, "uptime_ms": self.uptime, "event": event, "detail": detail}

    def frames(self) -> list[dict]:
        t = self.tick
        self.tick += 1
        s = self._state()
        if self.name == "example":
            return [s]
        if self.name == "jump":
            # 5.0 s counts down to 3.0 s, then the green is extended to 12 s (repeats every 3 s).
            step = t % 6
            remaining = 12000 if step == 5 else 5000 - step * 500
            s["timing"]["remaining_ms"] = remaining
            s["timing"]["elapsed_ms"] = 22000 - remaining
            return [s]
        if self.name == "missing":
            for key in ("timing", "plan", "health"):
                s.pop(key, None)
            s["signals"].pop("E", None)
            s["approaches"]["N"].pop("queued", None)
            s["vehicles"] = [{"id": "V09"}]
            s["mode"] = "turbo"  # unexpected value: shown as is, no crash
            return [s]
        if self.name == "emergency":
            out = []
            cycle = t % 20
            if cycle == 2:
                out.append(self._event("ev_request", "V05 E granted"))
                out.append(self._event("preempt_start", "V05 E"))
            if 2 <= cycle < 14:
                s["ctrl"] = "preempt"
                s["preempt"] = {"active": True, "approach": "E", "vehicle_id": "V05", "status": "granted"}
                s["approaches"]["E"]["ev"] = True
            if cycle == 14:
                out.append(self._event("preempt_end", "V05 cleared"))
            if cycle == 17:
                out.append(self._event("ev_request", "V06 N rejected"))
            out.append(s)
            return out
        if self.name == "fallback":
            s["ctrl"] = "fallback"
            s["mode"] = "fixed"
            s["v2i"].update({"link": "lost", "active_vehicles": 0, "pkts_per_s": 0.0, "last_pkt_ms_ago": 5000 + t * 500})
            out = [s]
            if t == 0:
                out.insert(0, self._event("v2i_lost", "no vehicle packets for 5 s"))
            return out
        if self.name == "version":
            s["v"] = 3
            return [s]
        if self.name == "restart":
            if t % 20 == 10:
                self.uptime = 0
                s["uptime_ms"] = 0
                return [self._event("restart", "power on"), s]
            return [s]
        raise SystemExit(f"unknown scenario {self.name}")


def _handshake(conn: socket.socket) -> bool:
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            return False
        data += chunk
        if len(data) > 65536:
            return False
    key = None
    for line in data.decode("latin-1").split("\r\n"):
        if line.lower().startswith("sec-websocket-key:"):
            key = line.split(":", 1)[1].strip()
    if not key:
        conn.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
        return False
    accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    conn.sendall(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept}\r\n\r\n".encode()
    )
    return True


def _text_frame(text: str) -> bytes:
    payload = text.encode()
    n = len(payload)
    if n < 126:
        header = struct.pack("!BB", 0x81, n)
    elif n < 65536:
        header = struct.pack("!BBH", 0x81, 126, n)
    else:
        header = struct.pack("!BBQ", 0x81, 127, n)
    return header + payload


def _drain(conn: socket.socket, stop: threading.Event) -> None:
    """Reads and ignores whatever the client sends; stops when it closes."""
    try:
        while not stop.is_set():
            if not conn.recv(4096):
                break
    except OSError:
        pass
    stop.set()


def _serve_client(conn: socket.socket, addr, scenario_name: str) -> None:
    try:
        if not _handshake(conn):
            return
        print(f"client connected: {addr[0]}:{addr[1]}")
        scenario = Scenario(scenario_name)
        stop = threading.Event()
        threading.Thread(target=_drain, args=(conn, stop), daemon=True).start()
        while not stop.is_set():
            for frame in scenario.frames():
                conn.sendall(_text_frame(json.dumps(frame)))
            time.sleep(0.5)
    except OSError:
        pass
    finally:
        conn.close()
        print(f"client disconnected: {addr[0]}:{addr[1]}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--scenario", default="example",
                        choices=["example", "jump", "missing", "emergency", "fallback", "version", "restart"])
    args = parser.parse_args()
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.host, args.port))
    server.listen(5)
    print(f"Test controller on ws://{args.host}:{args.port}/  scenario={args.scenario}  (Ctrl+C to stop)")
    try:
        while True:
            conn, addr = server.accept()
            threading.Thread(target=_serve_client, args=(conn, addr, args.scenario), daemon=True).start()
    except KeyboardInterrupt:
        pass
    finally:
        server.close()


if __name__ == "__main__":
    main()
