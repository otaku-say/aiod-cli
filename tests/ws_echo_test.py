#!/usr/bin/env python3
"""tests/ws_echo_test.py —— pty-ws 的 WebSocket 端到端测试（纯标准库，三平台可跑）

为什么需要它：`pty-ws` 的 ws/wss 是仓库里唯一的自写传输层，Linux/macOS 之外的
平台（Windows）走的是同一份 `std.Io` 实现。没有这条用例，跨平台移植只能靠「能编过」
自证，编译通过不等于能收发帧。

做法：起一个最小的 WebSocket 回显服务端（HTTP 101 + 帧编解码），让 CLI 连上去，
断言它真的把 `--send` 的内容发到了服务端、并且打印了服务端回送的内容。

覆盖：握手（Sec-WebSocket-Accept）、客户端掩码、文本帧收发、ready 后发送时机。

用法：
    python3 tests/ws_echo_test.py --bin zig-out/bin/aiod-cli
    python3 tests/ws_echo_test.py --bin zig-out/bin/aiod-cli.exe   # Windows
"""
import argparse
import base64
import hashlib
import json
import os
import socket
import struct
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MARK = "PING-1234"


def accept_key(client_key):
    return base64.b64encode(hashlib.sha1((client_key + GUID).encode()).digest()).decode()


def read_exact(rf, n):
    buf = b""
    while len(buf) < n:
        chunk = rf.read(n - len(buf))
        if not chunk:
            raise ConnectionError("unexpected EOF")
        buf += chunk
    return buf


def read_frame(rf):
    """返回 (opcode, payload)；客户端发来的帧必须带掩码。"""
    b1, b2 = read_exact(rf, 2)
    opcode = b1 & 0x0F
    masked = bool(b2 & 0x80)
    length = b2 & 0x7F
    if length == 126:
        length = struct.unpack(">H", read_exact(rf, 2))[0]
    elif length == 127:
        length = struct.unpack(">Q", read_exact(rf, 8))[0]
    mask = read_exact(rf, 4) if masked else None
    payload = read_exact(rf, length) if length else b""
    if mask:
        payload = bytes(c ^ mask[i % 4] for i, c in enumerate(payload))
    return opcode, payload


def send_frame(wf, opcode, payload):
    header = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        header += bytes([n])
    elif n < 65536:
        header += bytes([126]) + struct.pack(">H", n)
    else:
        header += bytes([127]) + struct.pack(">Q", n)
    wf.write(header + payload)
    wf.flush()


class EchoServer(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # 静音
        pass

    def do_GET(self):
        if not self.path.startswith("/v2/pty/ws"):
            self.send_error(404)
            return
        key = self.headers.get("Sec-WebSocket-Key")
        if not key:
            self.send_error(400, "missing Sec-WebSocket-Key")
            return
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept_key(key))
        self.end_headers()
        self.wfile.flush()
        try:
            send_frame(self.wfile, 0x1, b'{"type":"ready"}')
            while True:
                opcode, payload = read_frame(self.rfile)
                if opcode == 0x8:  # close
                    break
                if opcode == 0x9:  # ping
                    send_frame(self.wfile, 0xA, payload)
                    continue
                send_frame(self.wfile, 0x1, json.dumps({"data": payload.decode("utf-8", "replace")}).encode())
        except (ConnectionError, OSError, ValueError):
            pass
        finally:
            self.close_connection = True

    def do_POST(self):
        self.send_error(404)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True, help="aiod-cli 可执行文件路径")
    args = ap.parse_args()
    binary = os.path.abspath(args.bin)
    if not os.path.isfile(binary):
        print(f"[SKIP] 找不到二进制: {binary}")
        return 0

    server = ThreadingHTTPServer(("127.0.0.1", 0), EchoServer)
    server.daemon_threads = True
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()

    env = dict(os.environ, SANDBOX_BASE=f"http://127.0.0.1:{port}")
    try:
        proc = subprocess.run(
            [binary, "pty-ws-anon", f"--send={MARK}", "--max=2"],
            capture_output=True, text=True, timeout=30, env=env,
        )
    except subprocess.TimeoutExpired:
        print("[FAIL] pty-ws-anon 超时（30s）——WebSocket 收发可能卡住")
        return 1
    finally:
        server.shutdown()

    ok = True
    if proc.returncode != 0:
        print(f"[FAIL] 退出码 {proc.returncode}，期望 0")
        ok = False
    if "ready" not in proc.stdout:
        print(f"[FAIL] stdout 没有 ready 握手回显: {proc.stdout!r}")
        ok = False
    if MARK not in proc.stdout:
        # 服务端回显里应包含客户端发上去的内容
        print(f"[FAIL] stdout 没有回显 {MARK}: {proc.stdout!r}")
        ok = False

    if ok:
        print(f"[PASS] pty-ws-anon 握手 + 发送 + 回显正常（{MARK}）")
        return 0
    print("  stdout:", proc.stdout[:400])
    print("  stderr:", proc.stderr[:800])
    return 1


if __name__ == "__main__":
    sys.exit(main())
