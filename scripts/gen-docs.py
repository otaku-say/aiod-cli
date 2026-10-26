#!/usr/bin/env python3
"""scripts/gen-docs.py —— 从**已编译的二进制**生成 docs/aiod-cli.md。

为什么从二进制生成：docs 要与实际能跑的命令面逐字一致。手写文档必然漂移，
而 `<cmd> --help` 的内容就是 src/help.zig 里的命令表，编译后即事实。

用法（在仓库根目录执行，先 zig build 好）：
    python3 scripts/gen-docs.py
"""
import re
import subprocess
import sys
from pathlib import Path

BIN = Path("zig-out/bin/aiod-cli")
OUT = Path("docs/aiod-cli.md")

ALL_RE = re.compile(r"^【(.+?)】\s*$")
ROW_RE = re.compile(r"^  (\S+)\s\s+(.*)$")


def run(*args):
    p = subprocess.run([str(BIN), *args], capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"{BIN} {' '.join(args)} 退出码 {p.returncode}\n{p.stderr}")
    return p.stdout


def parse_table():
    """`help all` → [(分组, 命令名, 别名, 一句话)]"""
    out = []
    group = None
    for line in run("help", "all").splitlines():
        m = ALL_RE.match(line)
        if m:
            group = m.group(1)
            continue
        m = ROW_RE.match(line)
        if m and group:
            names = m.group(1).split("|")
            out.append((group, names[0], names[1] if len(names) > 1 else "", m.group(2).strip()))
    return out


def slug(name):
    # GitHub 锚点保留连字符：`### pty-ws` 的锚点是 #pty-ws，不是 #ptyws。
    # 同义词 `a|b` 已在 parse_table 拆分，name 里不会有 `|`。
    return name


def build_doc(table):
    lines = [
        "# aiod-cli 命令手册",
        "",
        "> **本文档由 `scripts/gen-docs.py` 从编译产物自动生成，请勿手工编辑。**",
        "> 权威命令面是 `<cli> help`（表在 `src/help.zig`）；文档随代码走，改命令先改 help。",
        "> 重新生成：",
        ">",
        "> ```bash",
        "> zig build -Doptimize=ReleaseFast",
        "> python3 scripts/gen-docs.py",
        "> ```",
        "",
        INTRO,
        "",
    ]
    lines += HEAD
    lines += ["", "## 命令索引", ""]
    cur = None
    for group, name, alias, brief in table:
        if group != cur:
            cur = group
            lines.append(f"- **{group}**")
        a = f"（同义词 `{alias}`）" if alias else ""
        lines.append(f"  - [`{name}`](#{slug(name)}) —— {brief}{a}")
    lines.append("")

    cur = None
    for group, name, alias, brief in table:
        if group != cur:
            cur = group
            lines.append(f"## {group}")
            lines.append("")
        lines.append(f"### {name}")
        lines.append("")
        detail = run("help", name)
        lines.append("```text")
        lines.append(detail.rstrip("\n"))
        lines.append("```")
        lines.append("")
        if "示例:" not in detail and "示例：" not in detail:
            sys.exit(f"{BIN} help {name} 缺少可复制运行的示例")
    return "\n".join(lines) + "\n"


INTRO = """`aiod-cli` 是 **沙箱内 aiod v2 API 遥控** CLI：命令执行、文件传输、PTY 终端、
代码解释器、浏览器、文件监听、MCP、桌面 computer-use。

- 建沙箱 / 选模板 / 快照 / 卷 是另一个工具 [`cube-cli`](https://github.com/otaku-say/cube-cli)。
- 源码：[`src/`](https://github.com/otaku-say/aiod-cli/tree/main/src)，命令表
  [`src/help.zig`](https://github.com/otaku-say/aiod-cli/blob/main/src/help.zig)。"""

HEAD = [
    "## 环境变量",
    "",
    "仓库内**不含任何主机名 / IP / 凭据**。只有 `SANDBOX_BASE` / `SANDBOX_KEY` 两个变量。",
    "",
    "| 变量 | 必填 | 用途 |",
    "|---|---|---|",
    "| `SANDBOX_BASE` | 是（`help` 除外） | aiod 网关地址。缺失时打印两种合法写法并以退出码 1 结束。 |",
    "| `SANDBOX_KEY` | 否 | 鉴权 Key。非空时同时附 `Authorization: Bearer <key>` 与 `X-API-Key: <key>`。 |",
    "",
    "### `SANDBOX_BASE` 的两种写法",
    "",
    "```bash",
    "# ① 带端口的完整网关（从本机 / 任何地方遥控沙箱）",
    "export SANDBOX_BASE=\"https://<网关>/sandbox/<sandboxID>/8080\"",
    "",
    "# ② 沙箱内自测：直接打回环",
    "export SANDBOX_BASE=\"http://127.0.0.1:8080\"",
    "```",
    "",
    "值来自 `cube-cli new` 打印的 `[sandbox] AIO 网关:` 那行。**末尾多余的 `/` 会被自动去掉**，"
    "所以带不带尾斜杠都行。端口也不总是 8080（轻量镜像是 18091），以 `cube-cli ports` 实测为准。",
    "",
    "## 构建与产物名",
    "",
    "需要 Zig **0.17.0**。linux / macos 的 arm64 与 amd64 都要能编过：",
    "",
    "```bash",
    "# 本机架构",
    "zig build -Doptimize=ReleaseFast",
    "# 交叉编译到 arm64（iSH / 手机 / ARM 服务器）",
    "zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-musl",
    "```",
    "",
    "产物名统一为 `aiod-cli-<os>-<arch>`；左边的三元组是 zig 编译器的 `-Dtarget=` 取值，原样照抄即可：",
    "",
    "| zig `-Dtarget=` 三元组 | 架构 | 产物文件名 | 用在哪 |",
    "|---|---|---|---|",
    "| `aarch64-linux-musl` | arm64 | `aiod-cli-linux-arm64` | iSH（iOS）、ARM 服务器 |",
    "| `x86_64-linux-musl` | amd64 | `aiod-cli-linux-amd64` | x86 服务器、桌面 Linux |",
    "| `aarch64-macos` | arm64 | `aiod-cli-macos-arm64` | Apple Silicon Mac |",
    "| `x86_64-macos` | amd64 | `aiod-cli-macos-amd64` | Intel Mac |",
    "",
    "本机构建产物在 `zig-out/bin/aiod-cli`，ReleaseFast + strip 后约 1.1 MB 静态单文件。",
    "",
    "## 快速上手",
    "",
    "```bash",
    "export SANDBOX_BASE=\"https://<网关>/sandbox/<sandboxID>/8080\"",
    "aiod-cli health",
    "aiod-cli sandbox-info",
    "aiod-cli exec 'zig version'",
    "aiod-cli write ./report.md /root/report.md && aiod-cli cat /root/report.md",
    "ID=$(aiod-cli async 'pip install -q pandas'); aiod-cli log \"$ID\" --follow",
    "```",
    "",
    "## 通用约定",
    "",
    "- 输出走 stdout，错误走 stderr 且**退出码非 0**。",
    "- 取值型 flag 一律 `--key=value`；布尔开关直接写 `--flag`。",
    "- 响应信封统一为 `{success, message, data, hint}`；非 2xx 或 `success=false` → "
    "`HTTP <码>: <message>（hint: …）`。",
    "- 命令列表里标注「源码未实现」的选项确实**没有**接线，源码里也只有注释提到过，别照抄旧文档。",
    "",
    "## 帮助怎么用",
    "",
    "```bash",
    "aiod-cli help              # 分组速查（≤60 行，常用命令）",
    "aiod-cli help all          # 完整命令表，一条一行",
    "aiod-cli help pty-ws       # 单命令详解（本文档对应小节）",
    "aiod-cli pty-ws --help     # 同上，**只打印不执行**",
    "aiod-cli pty-ws -h         # 同上",
    "```",
    "",
    "`help` 系列**不需要** `SANDBOX_BASE`。未知命令会打印「未知命令：xxx」并以退出码 1 结束。",
]


def main():
    if not BIN.is_file():
        sys.exit(f"找不到编译产物 {BIN}，请先 zig build -Doptimize=ReleaseFast")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    doc = build_doc(parse_table())
    OUT.write_text(doc, encoding="utf-8")
    print(f"wrote {OUT}  {len(doc.splitlines())} 行")


if __name__ == "__main__":
    main()
