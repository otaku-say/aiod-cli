# aiod-cli

沙箱内 **aiod v2 API** 遥控 CLI，Zig 实现，静态单文件分发。

一次 `export SANDBOX_BASE=...` 之后即可远程遥控一个 CubeSandbox 沙箱里的 aiod 服务：
命令执行、文件传输、PTY 终端、代码解释器、浏览器、文件监听、桌面 computer-use，
以及把这些能力整体暴露给 Agent 的 MCP Server。

本仓库是从 [`sandbox-cli`](https://github.com/otaku-say/sandbox-cli) 拆出来的独立工具仓库；
**建沙箱 / 选模板 / 快照 / 持久卷**属于控制面，在兄弟仓库
[`cube-cli`](https://github.com/otaku-say/cube-cli)。

版本号**跟随上游 aiod**，不因本仓库新增特性而单独递增：当前 `0.9.2`，对照记录见
`scripts/v2-coverage.json` 的 `spec.source`。上游发版后先跑漂移检查（见下），再同步版本号与命令面。

## 环境变量

**所有部署相关取值一律通过环境变量传入，仓库内不含任何主机名、IP 或凭据。**

| 变量 | 必填 | 说明 |
|---|---|---|
| `SANDBOX_BASE` | 是（`help` 除外） | aiod 网关地址。两种写法：`https://<网关>/sandbox/<sandboxID>/8080`（远程遥控）或 `http://127.0.0.1:8080`（沙箱内自测）。末尾多余的 `/` 会自动去掉。 |
| `SANDBOX_KEY` | 否 | 鉴权 Key（非空时附 `X-API-Key`；空串视同未设置） |

`SANDBOX_BASE` 的值就是 [`cube-cli`](https://github.com/otaku-say/cube-cli) `new` 打印的
`[sandbox] AIO 网关:` 那行（末尾的 `/` 无所谓）；端口也不总是 8080（轻量镜像是 18091），
以 `cube-cli ports` 实测为准。

## 构建

需要 Zig **0.17.0**。产物名统一为 `aiod-cli-<os>-<arch>`：

```bash
# 本机架构 → zig-out/bin/aiod-cli
zig build -Doptimize=ReleaseFast

# 交叉编译到 arm64（iSH / 手机 / ARM 服务器）
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-musl
```

| zig `-Dtarget=` 三元组 | 架构 | 产物文件名 | 用在哪 |
|---|---|---|---|
| `aarch64-linux-musl` | arm64 | `aiod-cli-linux-arm64` | iSH（iOS）、ARM 服务器 |
| `x86_64-linux-musl` | amd64 | `aiod-cli-linux-amd64` | x86 服务器、桌面 Linux |
| `aarch64-macos` | arm64 | `aiod-cli-macos-arm64` | Apple Silicon Mac |
| `x86_64-macos` | amd64 | `aiod-cli-macos-amd64` | Intel Mac |
| `aarch64-windows-gnu` | arm64 | `aiod-cli-windows-arm64.exe` | Windows on ARM |
| `x86_64-windows-gnu` | amd64 | `aiod-cli-windows-amd64.exe` | Windows x64 |

左边那列是 **zig 编译器自己的目标三元组**，是 `-Dtarget=` 的对外契约，原样照抄；
右边才是给人和发布产物用的 `<os>-<arch>` 命名（os 只有 `macos` / `windows` / `linux`，
arch 只有 `arm64` / `amd64`）。

linux / macos / windows 的 arm64 与 amd64 各目标都必须能编过；
ReleaseFast + strip 后 Linux/macOS 约 1.1–1.5 MB、Windows PE 约 1.6–2.0 MB，均为静态单文件。

## 命令速查：先看 `help`

**`help` 就是权威命令面。** 命令表在 `src/help.zig`，`docs/aiod-cli.md` 由
`scripts/gen-docs.py` 从**编译产物**自动生成——**文档随代码走**，改了命令先改 `help.zig`，
再跑一次生成脚本，README 不再重复维护命令清单。

```bash
aiod-cli help              # 分组速查（常用命令，≤60 行）
aiod-cli help all          # 完整命令表，一条一行
aiod-cli help pty-ws       # 单命令详解：用途 / 用法 / 参数 / 示例 / 注意
aiod-cli pty-ws --help     # 同上，且**只打印不执行**
aiod-cli pty-ws -h         # 同上
```

常用：

```bash
export SANDBOX_BASE="https://<网关>/sandbox/<sandboxID>/8080"
aiod-cli health
aiod-cli sandbox-info
aiod-cli exec 'zig version' --timeout=600000
aiod-cli write ./a.md /root/a.md && aiod-cli cat /root/a.md
aiod-cli br-go https://example.com && aiod-cli br-shot shot.png
ID=$(aiod-cli async 'sleep 60'); aiod-cli log "$ID" --follow; aiod-cli kill "$ID"
```

### 逐条文档

[`docs/aiod-cli.md`](docs/aiod-cli.md) —— 全部命令的逐条手册（由编译产物生成，勿手工编辑）。

重新生成：

```bash
zig build -Doptimize=ReleaseFast
python3 scripts/gen-docs.py
```

### 测试

```bash
sh tests/run_all.sh             # 一键全量：构建 → help 冒烟 → MCP 协议/纯净性 → 工具 mock → 图片边界 → 大文本 UTF-8 → 内存稳定 → 边界回归 → 对抗覆盖
sh tests/help_smoke.sh          # 只跑帮助体系冒烟（不依赖网络）
MEM_ITERS=1000 sh tests/run_all.sh   # 调小内存稳定测试的次数（默认 3000）
```

`tests/` 全部只用 Python 3 标准库，不依赖网络：

| 文件 | 覆盖 |
|---|---|
| `help_smoke.sh` | 帮助体系：五种入口等价、未知命令非 0 退出、`help` 不需要 `SANDBOX_BASE` |
| `mcp_protocol_test.py` | MCP 协议与 stdout 纯净性（版本协商、通知零输出、错误码矩阵、id 保真、畸形输入、32 MiB 边界、200 条顺序一致性…） |
| `mock_aiod_server.py` / `mcp_aiod_tools_test.py` | aiod-cli 全部 MCP 工具：结果 + mock 实收请求双向断言（含信封/HTTP/缺参三类异常映射） |
| `mcp_image_result_test.py` | 图片类工具边界：正常 PNG / 超 8 MiB / 非图片魔数 |
| `mcp_big_output_test.py` | 超 4 MiB 文本截断的 UTF-8 安全性（截断点落在汉字中间） |
| `mcp_mem_stability_test.py` | `mcp-server` 长驻进程的内存增长回归（分段增量中位数判据） |
| `adv_aiod_suite.py` / `adv_aiod_coverage.py` | 对抗面：参数毒化、超大文件、并发交替、全工具 3 类用例覆盖 |
| `aiod_edge_test.py` | 边界回归：`file_grep` 参数透传、可选参数类型错误必须报错 |

### 漂移检查（跟进上游 aiod）

长期纪律：aiod-cli 始终跟随 aiod 的 `/v2` API。`scripts/check-v2-drift.py` 把
「运行中的 aiod 网关 / 本地 OpenAPI 快照」与签入清单 `scripts/v2-coverage.json`
（74 个 v2 端点 → 命令 / 明确不做+原因）比对。

**它需要活体 aiod 网关，CI 里没有，所以没有 workflow，按下面命令手工跑**
（在沙箱里默认就是 `http://127.0.0.1:8080`）：

```bash
python3 scripts/check-v2-drift.py --base=https://<网关>/sandbox/<sid>/8080
python3 scripts/check-v2-drift.py --openapi=/path/openapi.json      # 离线快照模式
```

判读输出：

- **① 新增端点**（上游有、清单无）= **需要跟进**：给 CLI 补命令，或在清单标 `not-planned` + 原因；
- **② 消失端点**（清单有、上游无）= 上游删除/改名 → 复核清单；
- **③ 覆盖统计** = implemented（有命令）/ not-planned（明确不做）计数；
- **退出码**：0 = 无漂移；1 = 有漂移；2 = 拉取/清单错误。

清单只由维护者更新（脚本只报告差异、不自动改清单）。`--json` 拿机器可读结果。

## MCP Server（Agent 接口）

`aiod-cli mcp-server` 把全部能力暴露成 **Model Context Protocol (MCP)** 工具。
MCP Client（Claude Desktop、Cursor、Cline 等）把二进制作为子进程拉起，走 stdio 传输与
JSON-RPC 2.0 协议闭环调用沙箱能力。

### 客户端配置示例

```json
{
  "mcpServers": {
    "aiod-data": {
      "command": "/path/to/aiod-cli",
      "args": ["mcp-server"],
      "env": {
        "SANDBOX_BASE": "https://<网关>/sandbox/<sandboxID>/8080"
      }
    }
  }
}
```

> **缺配置不退出**：启动时缺少环境变量不会崩溃退出，仍能正常响应 `initialize` 与 `tools/list`；
> 仅在具体工具被调用且缺少配置时返回友好的 `isError: true` 错误提示（指引补充 `SANDBOX_BASE`）。

### 工具分组（工具名为 `snake_case`）

按 `src/mcp_tools_*.zig` 分六个域：**命令执行与会话**、**文件系统**、**PTY 终端**、
**浏览器自动化**、**桌面与 GUI 操作**、**杂项**（代码执行 / 文件监听 / MCP Hub / 沙箱画像）。

**完整工具清单不在本文件手抄**（手抄必然漂移）：一律以 `tools/list` 的实际输出为准。
不需要沙箱也能拉：

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | aiod-cli mcp-server
```

### stdout 纯净性承诺

- **绝对无协议外噪音**：stdio 模式下 stdout 只出现「单行、以 `\n` 结尾、可严格被 JSON 解析」的
  JSON-RPC 2.0 消息；绝对不输出 banner、进度条、ANSI 颜色代码或任何非协议文本。
- **诊断分流至 stderr**：所有日志、警告与诊断信息均通过 stderr 输出。

### 已知限制

遵循 MCP 规范及设计边界，以下特性明确不做：

- **不支持批处理**：JSON-RPC 顶层批量请求数组返回 `-32600 Invalid Request`。
- **无流式/进度通知**：仅接收客户端 `notifications/*`，不下发；不支持 resources 与 prompts。
- **无 follow 类工具**：长驻阻塞循环（`log --follow`、`pty-read` 等）不暴露为 MCP 工具。
- **仅提供 stdio 传输**：不内置 SSE 或 HTTP 传输，保持单二进制静态分发的纯粹性。

## 为什么是 Zig

这个工具在 iOS 的 iSH（Linux 用户态环境）里频繁调用，**进程启动开销是主要成本**。
同一任务（HTTPS GET + 自定义请求头）的实测：

| 语言 | 纯启动 | 二进制 |
|---|---|---|
| Go | ~170 ms | 5.3 MB |
| **Zig** | **~2 ms** | **~1 MB** |

Go 的 ~170 ms 是 runtime 初始化的固定开销（与二进制体积无关）。Zig 静态链接 musl，
无 runtime、无 GC，启动接近 C 程序。

其他收益：**零第三方依赖**（HTTP/TLS/JSON 全在标准库）、交叉编译内置
（`-Dtarget=aarch64-linux-musl` 一条命令，无需额外工具链）。

## DNS 容错（iSH 等环境必需）

Zig 标准库的解析器**不会跳过不可达的 nameserver**。若 `/etc/resolv.conf` 把 IPv6
链路本地地址（`fe80::/10`）排在第一位——iSH for iOS 正是如此——它会拿这个地址直接查询，
报文发不出去就整个解析以 `error.NameServerFailure` 收场，每次还要空耗数秒超时。
musl libc 会自动跳过这类地址，所以同一台机器上 `curl` 一切正常，`aiod-cli` 却连
一个域名都解析不出来。

`src/netfix.zig` 解决了这个问题：启动时若检测到此类地址，就在**进程内**接管域名解析
（注入 `std.Io` 的 `netLookup`），过滤掉不可达的 nameserver 后用其余地址查询。
**不改系统文件、不依赖 libc、不引入第三方依赖**；配置正常时不安装任何钩子（零开销）。

实现要点（都是踩过的坑，改之前先读）：

- `Io.Threaded` 的 `netLookup` 内部用的是**它自己的 io**（`t.io()`），不是调用方传入的
  那个。因此"把 `/etc/resolv.conf` 重定向到副本"这类文件层做法会被绕过（strace 实证：
  它仍然打开真实文件）。唯一有效的注入点就是 `netLookup` 本身。
- 包装 `std.Io` 时，`Io.userdata` 必须**原样透传**——它是底层实现的私有数据（指向
  `Threaded` 实例）。换成自己的结构体会让其它 vtable 函数解引用错位，直接段错误。
- `hookNetLookup` 内部必须用**包装后的 io**（`g_io`），不能透传未包装的 `g_base`：
  否则 `ResolvConf.init` 的 `File.openAbsolute("/etc/resolv.conf")` 读到的是真身，
  过滤副本形同虚设——链路本地死服务器排第一时每次查询都空耗 5 秒超时。
- DNS 查询把全部 nameserver **一次性并行发送**（musl 同策略），按事务 ID 收包：
  黑洞型服务器（发包成功但不应答，如 iSH 的 198.18.0.1）只占一个在途报文，
  不会让健康服务器串行等待整轮超时。
- 查询实现复用标准库公开件：`HostName.ResolvConf.init(io)`（用我们包装过的 io 读过滤副本）、
  `HostName.DnsResponse`、`HostName.expand`；只有查询报文构造与 UDP 收发是自己写的。

## 代码结构

| 文件 | 职责 |
|---|---|
| `src/main.zig` | 入口、命令分发、`health` / `version` |
| `src/cfg.zig` | 环境变量 |
| `src/ctx.zig` | `Ctx`：io / client / arena / out / base / key |
| `src/httpc.zig` | HTTP 核心：`request` / `get` / `postJson` / `del` |
| `src/util.zig` | 参数解析 `Args`、鉴权头、输出辅助 |
| `src/cmd_exec.zig` | 命令执行：exec / async / log / kill / stdin / sess* |
| `src/cmd_files.zig` | 文件：cat / read / write / put / get / ls / tree / mkdir / rm / mv / cp / edit / grep / search / stat |
| `src/cmd_pty.zig` | 终端：pty / pty-new / pty-input / pty-screen / pty-signal / pty-resize / pty-ls / pty-rm / pty-ws |
| `src/cmd_browser.zig` | 浏览器 br-* 与 computer-use cmp-* |
| `src/cmd_misc.zig` | code / code-* / watch / watch-* / mcp / sandbox-info / sandbox-packages |
| `src/ws.zig`、`src/tls13.zig` | `pty-ws` 的 WebSocket / 手写 TLS 1.3 传输层（PoC 记录见 `docs/wss/`） |
| `src/sdk*.zig`、`src/mcp*.zig` | aiod v2 端点封装与 MCP 工具层 |

> 注意：`pty-ws` / `pty-ws-anon` 的 `wss://` 目前只校验证书主机名，不验证 CA 证书链
> （自签证书也能连接），存在中间人风险；请勿在不可信网络中使用。

### 开发约定（**重要**）

每个 `cmd_*.zig` 只导出一个入口：

```zig
pub fn dispatch(c: *Ctx, cmd: []const u8, args: []const []const u8) !bool {
    if (std.mem.eql(u8, cmd, "xxx")) { try doXxx(c, args); return true; }
    return false;
}
```

- 命中本模块负责的命令 → 执行并返回 `true`；不命中 → 返回 `false`
- **不要修改 `main.zig`**：模块已按固定顺序注册，只需改自己负责的文件

典型用法：

```zig
const argv = try util.parse(c.arena, args);
const path = argv.at(0) orelse return error.MissingArg;
const timeout = argv.get("timeout");

const url = try c.url("/v2/commands");
const buf = try c.arena.alloc(u8, util.BUF);
var storage: [3]std.http.Header = undefined;
const res = try httpc.postJson(c.client, url, util.jsonHeaders(c, &storage), body, buf);
try util.printOrFail(c, res);
```

## Zig 0.17 API 要点（与网上/模型记忆里的旧示例**完全不同**）

Zig 0.17 的标准库与旧版本差异很大（`std.io` → `std.Io`、`std.http.Client` 需注入 `io`、
`main` 签名改为接收 `std.process.Init`）。本仓库代码按 0.17 编写，**不要**参照基于 0.11–0.14 的示例。

| 旧写法（≤0.14） | 0.17 正确写法 |
|---|---|
| `std.io.Writer.fixed` | `std.Io.Writer.fixed` |
| `client.fetch(.{...})` 无 io | `client` 构造时**必须注入** `.io` |
| `fn main() !void` | `pub fn main(init: std.process.Init.Minimal) !void` |
| `std.process.argsAlloc` | `init.args.vector`（`[]const [*:0]const u8`，`std.mem.span` 转 slice） |
| `std.heap.GeneralPurposeAllocator` | `std.heap.DebugAllocator` / `std.heap.smp_allocator` |
| `std.io.fixedBufferStream` | 无（用 `std.Io.Writer.fixed` 或手写） |
| `std.mem.trimRight` | 无（手写） |
| `std.posix.getenv` | `std.c.getenv`（构建需 `link_libc`） |

HTTP 客户端初始化（`main.zig` 已做，模块内直接用 `c.client`）：

```zig
var threaded: std.Io.Threaded = .init(gpa, .{});
const io = threaded.io();
var client: std.http.Client = .{ .allocator = gpa, .io = io };
```

## 注意

- **flag 一律 `--key=value` 等号写法**（例：`--lang=python`）；布尔开关直接写 `--flag`。
- **未知命令**会打印「未知命令：xxx」并以**非 0** 退出码结束。
- `--help` / `-h` / `help <命令>` 三种写法等价，且**绝不触发真实操作**。
- 错误一律走 stderr：非 2xx、`success=false`、响应超上限截断都会转成可读错误并以非 0 退出，
  所以 `aiod-cli cat <文件> > out.txt` 的 out.txt 里不会混进错误 JSON。
- 文档里标了「源码未实现」的选项确实没有接线，别照抄旧文档。

## License

MIT，见 [LICENSE](LICENSE)。Copyright (c) 2026 otaku-say
