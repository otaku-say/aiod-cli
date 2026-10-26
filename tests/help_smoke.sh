#!/bin/sh
# tests/help_smoke.sh —— aiod-cli 帮助体系的冒烟测试（可重复执行，不依赖网络）
#
# 覆盖：
#   1. help / help all / help <cmd> / <cmd> --help / <cmd> -h 五种入口都能打印
#   2. 未知命令 / help <未知> → "未知命令：xxx" + 非 0 退出
#   3. 缺 SANDBOX_BASE 时的报错是否清晰；help 不需要该变量
#   4. 顶层 help 行数 ≤ 60
#   5. version 的仓库地址与新产物命名（<tool>-<os>-<arch>）
#
# 用法：
#   AIO=/path/to/aiod-cli tests/help_smoke.sh   # 默认 zig-out/bin/aiod-cli
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
AIO=${AIO:-$ROOT/zig-out/bin/aiod-cli}
[ -x "$AIO" ] || { echo "找不到 aiod-cli: $AIO"; exit 1; }

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

# check <名称> <期望退出码> <命令…>
check() {
    name=$1; want=$2; shift 2
    out=$("$@" 2>&1); rc=$?
    if [ "$rc" -eq "$want" ]; then ok "$name (exit $rc)"
    else bad "$name (exit $rc，期望 $want)"; printf '%s\n' "$out" | sed 's/^/        /' | head -5; fi
    printf '%s' "$out"
}

echo "== 1. 顶层 help =="
AIO_LINES=$("$AIO" help | wc -l | tr -d ' ')
if [ "$AIO_LINES" -le 60 ]; then ok "aiod-cli help = $AIO_LINES 行 (≤60)"
else bad "aiod-cli help = $AIO_LINES 行 (>60)"; fi
check "aiod-cli --help"         0 "$AIO" --help >/dev/null
check "aiod-cli -h"             0 "$AIO" -h     >/dev/null
check "aiod-cli（无参数）"      0 "$AIO"        >/dev/null

echo "== 2. help all =="
check "aiod-cli help all" 0 "$AIO" help all >/dev/null

echo "== 3. help <命令> / <命令> --help / <命令> -h 三种写法等价 =="
for c in exec pty-ws br-cookie-set cmp-a11y mcp-server; do
    a=$("$AIO" help "$c" 2>&1)
    b=$("$AIO" "$c" --help 2>&1)
    d=$("$AIO" "$c" -h 2>&1)
    if [ "$a" = "$b" ] && [ "$b" = "$d" ] && [ -n "$a" ]; then
        ok "aiod-cli $c：三种写法输出完全一致"
    else
        bad "aiod-cli $c：三种写法输出不一致"
    fi
done

echo "== 4. 未知命令（非 0 退出 + 提示） =="
o=$("$AIO" frobnicate 2>&1); rc=$?
case "$o" in *"未知命令"*) ok "aiod-cli 未知命令有提示" ;; *) bad "aiod-cli 未知命令无提示" ;; esac
[ "$rc" -ne 0 ] && ok "aiod-cli 未知命令退出码 $rc" || bad "aiod-cli 未知命令退出码为 0"
o=$("$AIO" help frobnicate 2>&1); rc=$?
case "$o" in *"未知命令"*) ok "aiod-cli help <未知> 有提示" ;; *) bad "aiod-cli help <未知> 无提示" ;; esac
[ "$rc" -ne 0 ] && ok "aiod-cli help <未知> 退出码 $rc" || bad "aiod-cli help <未知> 退出码为 0"

echo "== 5. aiod-cli 缺 SANDBOX_BASE 的报错 =="
o=$(env -u SANDBOX_BASE "$AIO" exec 'echo hi' 2>&1); rc=$?
case "$o" in *SANDBOX_BASE*) ok "报错点明了 SANDBOX_BASE" ;; *) bad "报错没提 SANDBOX_BASE"; printf '%s\n' "$o" | sed 's/^/        /' ;; esac
case "$o" in *"127.0.0.1:8080"*|*"sandbox/"*) ok "报错给出了 SANDBOX_BASE 的两种写法" ;; *) bad "报错没给两种写法示例" ;; esac
[ "$rc" -ne 0 ] && ok "缺变量时退出码 $rc" || bad "缺变量时退出码为 0"
o=$(env -u SANDBOX_BASE "$AIO" help 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -n "$o" ] && ok "help 不需要 SANDBOX_BASE" || bad "help 在缺 SANDBOX_BASE 时失败"
o=$(env -u SANDBOX_BASE "$AIO" exec --help 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -n "$o" ] && ok "exec --help 不需要 SANDBOX_BASE" || bad "exec --help 在缺 SANDBOX_BASE 时失败"
o=$(env -u SANDBOX_BASE "$AIO" mcp-server --help 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -n "$o" ] && ok "mcp-server --help 不需要 SANDBOX_BASE 且退出码为 0" || bad "mcp-server --help 在缺 SANDBOX_BASE 时失败"

echo "== 6. version：仓库与构建信息、产物命名 =="
"$AIO" version 2>&1 | grep -q 'github.com/otaku-say/aiod-cli' \
    && ok "aiod-cli version 含仓库地址" || bad "aiod-cli version 缺仓库地址"
"$AIO" version 2>&1 | grep -q 'Zig 0.17.0' \
    && ok "aiod-cli version 含构建信息" || bad "aiod-cli version 缺构建信息"
"$AIO" version 2>&1 | grep -q 'aiod-cli-linux-arm64' \
    && ok "aiod-cli version 产物名用 arm64 命名" || bad "aiod-cli version 产物名不是 <tool>-<os>-<arch>"

echo
echo "结果：$PASS 通过 / $FAIL 失败"
[ "$FAIL" -eq 0 ] || exit 1
