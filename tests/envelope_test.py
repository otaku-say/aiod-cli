#!/usr/bin/env python3
"""信封与截断回归（审计修复 M1/M2）。

两类静默假成功曾把脚本带沟里：
  M1  HTTP 200 + success=false 被当成功 → `exec 'make' && ./deploy.sh` 构建失败也继续部署
  M2  响应体超过客户端 buf → 半截 JSON 被当正文打到 stdout、退出 0

断言：非 0 退出、stdout 不被污染、stderr 有可读原因。
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ROOT)
from mock_aiod_server import MockAiodServer

BIN = os.path.join(ROOT, "../zig-out/bin/aiod-cli")


def main():
    srv = MockAiodServer()
    srv.start()
    env = dict(os.environ, SANDBOX_BASE=srv.base_url)
    env.pop("SANDBOX_KEY", None)
    fails = []

    def run(args):
        return subprocess.run([BIN, *args], capture_output=True, text=True, env=env)

    def check(name, cond, info=""):
        print(f"  {'ok  ' if cond else 'FAIL'} {name}" + ("" if cond else f"   [{info}]"))
        if not cond:
            fails.append(name)

    # M1：mock 的 fail_api 分支在 body 里命中即回 200 + success=false
    p = run(["exec", "echo hi", "--cwd=fail_api=true"])
    check("M1 exec: 200+success=false → 非 0 退出", p.returncode != 0, f"rc={p.returncode}")
    check("M1 exec: stdout 无错误内容", p.stdout.strip() == "", repr(p.stdout[:80]))
    check(
        "M1 exec: stderr 有 HTTP 200 与 message",
        "HTTP 200" in p.stderr and "模拟 API 业务错误" in p.stderr,
        repr(p.stderr[:120]),
    )

    # M2：9 MiB 响应 > 命令侧 8 MiB buf
    p = run(["cat", "/big-trunc"])
    check("M2 cat: 超缓冲截断 → 非 0 退出", p.returncode != 0, f"rc={p.returncode}")
    check("M2 cat: stdout 不输出半截信封", p.stdout == "", f"len={len(p.stdout)}")
    check("M2 cat: stderr 提示已截断", "截断" in p.stderr, repr(p.stderr[:120]))

    srv.stop()
    print(f"-- 信封/截断回归：失败 {len(fails)} 项 --")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
