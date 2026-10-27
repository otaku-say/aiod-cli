#!/usr/bin/env python3
"""tests/exit_code_test.py —— exec 退出码是否按上游 exit_code 透传（纯标准库，三平台可跑）

为什么需要它：远端命令失败而 CLI 退出 0，会让 `aiod-cli exec 'make' && ./deploy.sh`
继续部署。这条规则之前没有任何断言守着，改坏了不会有人发现。

上游契约（aiod /v2/commands 与 CubeSandbox SDK CommandResult）都直接给 exit_code，
所以本进程的退出码必须和它一致：
    exit_code >= 0 → 原样（0 = 成功，1-255 = 失败）
    status = timed_out → 124（同 timeout(1)）
    exit_code <  0 → 1（上游没给合法 shell 码，如被信号杀死）

用法：
    python3 tests/exit_code_test.py --bin zig-out/bin/aiod-cli
    python3 tests/exit_code_test.py --bin zig-out/bin/aiod-cli.exe
"""
import argparse
import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

REPLY = {"exit_code": 0, "status": "completed"}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        body = json.dumps({
            "success": True,
            "message": "ok",
            "data": {
                "command_id": "cmd-1",
                "status": REPLY["status"],
                "stdout": "out",
                "stderr": "",
                "exit_code": REPLY["exit_code"],
                "offset": 3,
            },
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()


def run_case(binary, url, exit_code, status):
    REPLY["exit_code"] = exit_code
    REPLY["status"] = status
    env = dict(os.environ, SANDBOX_BASE=url)
    env.pop("SANDBOX_KEY", None)
    p = subprocess.run([binary, "exec", "true"], capture_output=True, text=True, timeout=30, env=env)
    return p.returncode, p.stdout, p.stderr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True)
    args = ap.parse_args()
    binary = os.path.abspath(args.bin)
    if not os.path.isfile(binary):
        print(f"[SKIP] 找不到二进制: {binary}")
        return 0

    srv = HTTPServer(("127.0.0.1", 0), Handler)
    url = f"http://127.0.0.1:{srv.server_address[1]}"
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    cases = [
        ("成功 exit_code=0", 0, "completed", 0),
        ("失败 exit_code=7", 7, "completed", 7),
        ("失败 exit_code=250", 250, "completed", 250),
        ("硬超时 status=timed_out", -1, "timed_out", 124),
        ("被信号杀死 exit_code=-1", -1, "killed", 1),
    ]
    fails = 0
    try:
        for name, code, status, want in cases:
            got, out, err = run_case(binary, url, code, status)
            if got == want:
                print(f"  ok   {name} → 退出码 {got}")
            else:
                fails += 1
                print(f"  FAIL {name} → 退出码 {got}，期望 {want}；stderr={err[:160]!r}")
            # 「（exit N）」提示不许进 stdout，否则 OUT=$(...) 会被污染
            if code != 0 and "（exit" in out:
                fails += 1
                print(f"  FAIL {name}: 「（exit N）」进了 stdout：{out[:120]!r}")
    finally:
        srv.shutdown()

    print(f"-- 退出码语义：{len(cases) - fails} 通过 / {fails} 失败 --")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
