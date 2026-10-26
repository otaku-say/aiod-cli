#!/bin/sh
# tests/run_all.sh —— aiod-cli 一键全量测试套件
#
# 步骤：
#   1. zig build (Debug)
#   2. tests/help_smoke.sh 帮助体系冒烟测试
#   3. tests/mcp_protocol_test.py 协议 + 纯净性测试
#   4. tests/mcp_aiod_tools_test.py mock 工具套件
#   5. tests/mcp_image_result_test.py 图片类工具结果边界
#   6. tests/mcp_big_output_test.py 大文本截断的 UTF-8 安全性
#   7. tests/mcp_mem_stability_test.py MCP Server 内存增长稳定性回归
#   8. tests/aiod_edge_test.py 边界回归（参数透传 / 可选参数类型错误）
#   9. 对抗测试套件（全工具覆盖 + 对抗面）
#  10. 信封/截断回归（HTTP 200 + success:false、响应超缓冲）
#
# 失败即非 0 退出；输出能一眼看出哪一步失败。
# MEM_ITERS 可调小内存稳定测试的调用次数（默认 3000）。

set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
AIO="$ROOT/zig-out/bin/aiod-cli"

echo "=================================================="
echo "== [1/10] 编译 aiod-cli (Debug) =="
echo "=================================================="
(cd "$ROOT" && zig build)
echo "[PASS] aiod-cli 编译成功"
echo ""

echo "=================================================="
echo "== [2/10] 帮助体系冒烟测试 (tests/help_smoke.sh) =="
echo "=================================================="
AIO="$AIO" sh "$ROOT/tests/help_smoke.sh"
echo "[PASS] help_smoke.sh 全部通过"
echo ""

echo "=================================================="
echo "== [3/10] MCP 协议与纯净性测试 (tests/mcp_protocol_test.py) =="
echo "=================================================="
python3 "$ROOT/tests/mcp_protocol_test.py" --bin "$AIO" --tools-min 65
echo "[PASS] mcp_protocol_test.py 全部通过"
echo ""

echo "=================================================="
echo "== [4/10] mock 工具测试套件 =="
echo "=================================================="
python3 "$ROOT/tests/mcp_aiod_tools_test.py" --bin "$AIO"
echo "[PASS] mcp_aiod_tools_test.py 全部通过"
echo ""

echo "=================================================="
echo "== [5/10] 图片类工具结果边界（超限/非图片） =="
echo "=================================================="
python3 "$ROOT/tests/mcp_image_result_test.py" --bin "$AIO"
echo "[PASS] mcp_image_result_test.py 全部通过"
echo ""

echo "=================================================="
echo "== [6/10] 大文本截断的 UTF-8 安全性 =="
echo "=================================================="
python3 "$ROOT/tests/mcp_big_output_test.py" --bin "$AIO"
echo "[PASS] mcp_big_output_test.py 全部通过"
echo ""

echo "=================================================="
echo "== [7/10] MCP Server 内存稳定性回归 (tests/mcp_mem_stability_test.py) =="
echo "=================================================="
python3 "$ROOT/tests/mcp_mem_stability_test.py" --bin "$AIO" --iters "${MEM_ITERS:-3000}"
echo "[PASS] mcp_mem_stability_test.py 全部通过"
echo ""

echo "=================================================="
echo "== [8/10] 边界回归（参数透传 / 可选参数类型错误） =="
echo "=================================================="
python3 "$ROOT/tests/aiod_edge_test.py" --bin "$AIO"
echo "[PASS] aiod_edge_test.py 全部通过"
echo ""

echo "=================================================="
echo "== [9/10] 对抗测试套件（全工具覆盖 + 对抗面） =="
echo "=================================================="
python3 "$ROOT/tests/adv_aiod_suite.py"
python3 "$ROOT/tests/adv_aiod_coverage.py"
echo "[PASS] 对抗测试套件全部通过"
echo ""

echo "=================================================="
echo "== [10/10] 信封与截断回归（M1/M2） =="
echo "=================================================="
python3 "$ROOT/tests/envelope_test.py"
echo "[PASS] envelope_test.py 全部通过"
echo ""

echo "=================================================="
echo "== 全量测试完成：全部步骤成功通过！ =="
echo "=================================================="
