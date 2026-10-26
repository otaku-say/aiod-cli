#!/usr/bin/env python3
"""边界回归（反空跑）：两条只在 aiod-cli 上成立的旧缺陷断言。

  1. file_grep 必须把 include / context / offset / type 透传到 /v2/fs/grep
  2. 可选字符串参数类型不符（file_read 的 user 传数字）→ 必须报「参数错误」，不许静默忽略

这两条原先混在 sandbox-cli 的 mcp_cube_edge_test.py 里（其余用例全是 cube-cli 的），
拆仓库时单独留在本仓库。

用法: python3 tests/aiod_edge_test.py --bin <aiod-cli>
"""
import argparse
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mock_aiod_server import MockAiodServer  # noqa: E402

FAILS = []


def ok(msg):
    print(f"  ok   {msg}")


def bad(msg):
    FAILS.append(msg)
    print(f"  FAIL {msg}")


class Mcp:
    def __init__(self, binary, base):
        env = {k: v for k, v in os.environ.items() if not k.startswith("SANDBOX_")}
        env["SANDBOX_BASE"] = base
        self.p = subprocess.Popen([binary, "mcp-server"], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                  env=env, bufsize=0)
        self.n = 0
        self.call("initialize", {"protocolVersion": "2025-06-18"})

    def call(self, method, params):
        self.n += 1
        req = {"jsonrpc": "2.0", "id": self.n, "method": method}
        if params is not None:
            req["params"] = params
        self.p.stdin.write((json.dumps(req) + "\n").encode())
        self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())

    def tool(self, name, args):
        r = self.call("tools/call", {"name": name, "arguments": args})
        res = r.get("result")
        if res is None:
            return {"is_error": True, "text": str(r.get("error"))}
        return {"is_error": res.get("isError", False),
                "text": "".join(c.get("text", "") for c in res.get("content", [])
                                if c.get("type") == "text")}

    def close(self):
        try:
            self.p.kill()
        except Exception:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True)
    args = ap.parse_args()

    srv = MockAiodServer()
    srv.start()
    mcp = Mcp(args.bin, srv.base_url)

    srv.clear_requests()
    mcp.tool("file_grep", {"path": "/tmp", "pattern": "x", "include": ["*.zig"],
                           "context": 2, "offset": 5, "type": "zig"})
    grep_body = next((r["body"] for r in srv.requests() if r["path"] == "/v2/fs/grep"), "")
    want = ('"include":["*.zig"]', '"context_before":2', '"offset":5', '"type":"zig"')
    missing = [w for w in want if w not in grep_body]
    if missing:
        bad(f"file_grep 未透传 {missing}；实际 body={grep_body[:200]}")
    else:
        ok("file_grep 透传 include/context/offset/type")

    r = mcp.tool("file_read", {"path": "/etc/hosts", "user": 123})
    if r["is_error"] and "参数错误" in r["text"]:
        ok("可选字符串参数类型错误 → 参数错误")
    else:
        bad(f"可选字符串类型错误未报参数错误：{r}")

    mcp.close()
    srv.stop()

    print(f"-- 边界回归：{len(FAILS)} 项不符预期 --")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
