//! PTY 终端：pty-new / pty-ls / pty / pty-screen / pty-input / pty-signal / pty-resize / pty-rm
//!
//! aiod v2：
//!   POST   /v2/pty/sessions                {"id","cwd","cols","rows","retention"}
//!   GET    /v2/pty/sessions
//!   POST   /v2/pty/sessions/<id>/exec      {"command","timeout","async"} → data.output（合流）
//!   GET    /v2/pty/sessions/<id>/screen
//!   POST   /v2/pty/sessions/<id>/input     {"input","press_enter"}
//!   POST   /v2/pty/sessions/<id>/signal    {"signal"}
//!   PATCH  /v2/pty/sessions/<id>           {"cols","rows"}
//!   DELETE /v2/pty/sessions/<id>
//!
//! 注（Go 版实测备注）：--timeout 到点会返回 status=running（命令仍在跑），
//! 此时再 exec 会被拒（Session already has a running command），可用 pty-screen 看进度；
//! signal 会把会话进程终止（会话随后从列表消失）。
//!
//! pty-ws / pty-ws-anon（WebSocket 附着）：ws://（明文）与 wss://（在 socket
//! 之上套手写 TLS 1.3 客户端 tls13.zig，无 fork / 无 openssl）。
//! wss 下默认做证书主机名校验；自签证书调试可用 -k / --insecure 跳过。
const std = @import("std");
const ctxmod = @import("ctx.zig");
const util = @import("util.zig");
const httpc = @import("httpc.zig");
const sdkmod = @import("sdk.zig");

const Ctx = ctxmod.Ctx;
const BUF = 8 << 20;

/// 打印错误响应并返回错误（返回 anyerror 以便在任意返回类型的函数里直接 return）。
fn auth(c: *Ctx) !httpc.Headers {
    const hs = try c.arena.alloc(std.http.Header, 2);
    var n: usize = 0;
    hs[n] = .{ .name = "Accept", .value = "application/json" };
    n += 1;
    if (c.key) |k| {
        hs[n] = .{ .name = "X-API-KEY", .value = k };
        n += 1;
    }
    return hs[0..n];
}

fn jsonAuth(c: *Ctx) !httpc.Headers {
    const hs = try c.arena.alloc(std.http.Header, 3);
    var n: usize = 0;
    hs[n] = .{ .name = "Accept", .value = "application/json" };
    n += 1;
    hs[n] = httpc.json_ct;
    n += 1;
    if (c.key) |k| {
        hs[n] = .{ .name = "X-API-KEY", .value = k };
        n += 1;
    }
    return hs[0..n];
}

fn out(c: *Ctx, res: httpc.Response) !void {
    try c.out.print("{s}\n", .{res.body});
}

/// 会话id 会拼进 URL 路径（urlEncode 不转义 '.' 和 '/'，`..` 可穿越路径）；
/// 创建入口与非创建入口用同一套字符集校验。
fn idArg(c: *Ctx, a: util.Args) ![]const u8 {
    const id = a.at(0) orelse return error.MissingArg;
    if (!sdkmod.validId(id)) {
        try c.err.print("会话id 非法：{s}（只能包含字母、数字和 . _ -）\n", .{id});
        return error.BadId;
    }
    return id;
}

/// pty-new <会话id> [--cwd=] [--cols=] [--rows=] [--retention=]
fn cmdNew(c: *Ctx, a: util.Args) !void {
    const id = try idArg(c, a);
    var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 16 << 10));
    try w.print("{{\"id\":\"{s}\"", .{try util.jsonEscape(c.arena, id)});
    if (a.get("cwd")) |v| try w.print(",\"cwd\":\"{s}\"", .{try util.jsonEscape(c.arena, v)});
    if (try util.intFlag(c, a, "cols")) |v| try w.print(",\"cols\":{d}", .{v});
    if (try util.intFlag(c, a, "rows")) |v| try w.print(",\"rows\":{d}", .{v});
    if (a.get("retention")) |v| try w.print(",\"retention\":\"{s}\"", .{try util.jsonEscape(c.arena, v)});
    if (a.get("user")) |v| try w.print(",\"user\":\"{s}\"", .{try util.jsonEscape(c.arena, v)});
    if (try util.intFlag(c, a, "no-change-timeout")) |v| try w.print(",\"no_change_timeout\":{d}", .{v});
    try w.print("}}", .{});
    const buf = try c.arena.alloc(u8, BUF);
    const res = try httpc.postJson(c.client, try c.url("/v2/pty/sessions"), try jsonAuth(c), w.buffered(), buf);
    try util.checkResp(c, res);
    try out(c, res);
}

/// pty <会话id> <命令...> [--timeout=] [--async]
fn cmdExec(c: *Ctx, a: util.Args) !void {
    const id = a.at(0) orelse return error.MissingArg;
    if (a.pos.len < 2) return error.MissingArg;
    var cmd_txt: []const u8 = a.pos[1];
    for (a.pos[2..]) |p| cmd_txt = try std.fmt.allocPrint(c.arena, "{s} {s}", .{ cmd_txt, p });

    var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 64 << 10));
    try w.print("{{\"command\":\"{s}\"", .{try util.jsonEscape(c.arena, cmd_txt)});
    if (try util.intFlag(c, a, "timeout")) |v| try w.print(",\"timeout\":{d}", .{v});
    if (a.has("async")) try w.print(",\"async\":true", .{});
    if (try util.intFlag(c, a, "hard-timeout")) |v| try w.print(",\"hard_timeout\":{d}", .{v});
    if (try util.intFlag(c, a, "no-change-timeout")) |v| try w.print(",\"no_change_timeout\":{d}", .{v});
    try w.print("}}", .{});

    const path = try std.fmt.allocPrint(c.arena, "/v2/pty/sessions/{s}/exec", .{try util.urlEncode(c.arena, id)});
    const buf = try c.arena.alloc(u8, BUF);
    // exec 可能等满 timeout，HTTP 侧给足余量
    const res = try httpc.postJson(c.client, try c.url(path), try jsonAuth(c), w.buffered(), buf);
    try util.checkResp(c, res);
    try out(c, res);
}

fn cmdGet(c: *Ctx, path: []const u8) !void {
    const buf = try c.arena.alloc(u8, BUF);
    const res = try httpc.get(c.client, try c.url(path), try auth(c), buf);
    try util.checkResp(c, res);
    try out(c, res);
}

fn cmdSend(c: *Ctx, path: []const u8, body: []const u8, method: httpc.Method) !void {
    const buf = try c.arena.alloc(u8, BUF);
    const res = try httpc.request(c.client, method, try c.url(path), try jsonAuth(c), body, buf);
    try util.checkResp(c, res);
    try out(c, res);
}

// ---------------- pty-ws（WebSocket 附着） ----------------

const ws = @import("ws.zig");

const BaseInfo = struct {
    host: []const u8,
    port: u16,
    path_prefix: []const u8,
    tls: bool,
};

/// 解析 SANDBOX_BASE（http(s)://host[:port][/path]）。
fn parseBase(base: []const u8) !BaseInfo {
    const sep = std.mem.indexOf(u8, base, "://") orelse return error.BadBase;
    const scheme = base[0..sep];
    const rest = base[sep + 3 ..];
    const tls = std.mem.eql(u8, scheme, "https") or std.mem.eql(u8, scheme, "wss");
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    const path_prefix = if (slash < rest.len) rest[slash..] else "";
    var host = authority;
    var port: u16 = if (tls) 443 else 80;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |ci| {
        // 注意 IPv6 字面量的 [::1]:8080 形式
        if (ci > 0 and authority[ci - 1] != ']') {
            host = authority[0..ci];
            port = std.fmt.parseInt(u16, authority[ci + 1 ..], 10) catch port;
        }
    }
    // 去掉 IPv6 的方括号
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') {
        host = host[1 .. host.len - 1];
    }
    return .{ .host = host, .port = port, .path_prefix = path_prefix, .tls = tls };
}

/// pty-ws <会话id> [--send=文本] [--max=条数] [--raw] [--insecure|-k]
///
/// SANDBOX_BASE 为 https:// 时自动走 wss://（TLS 1.3 手写实现）。
fn cmdPtyWs(c: *Ctx, anon: bool, a: util.Args) !void {
    if (!anon) _ = try idArg(c, a);

    const info = parseBase(c.base) catch {
        try c.err.print("无法解析 SANDBOX_BASE: {s}\n", .{c.base});
        return error.BadBase;
    };

    var wq = std.Io.Writer.fixed(try c.arena.alloc(u8, 1024));
    if (anon) {
        try wq.print("{s}/v2/pty/ws?protocol=json", .{info.path_prefix});
    } else {
        try wq.print("{s}/v2/pty/sessions/{s}/ws?protocol=json", .{ info.path_prefix, try util.urlEncode(c.arena, a.at(0).?) });
    }
    if (a.has("durable")) try wq.print("&durable=true", .{});
    if (a.has("restore")) try wq.print("&restore=true", .{});
    if (try util.intFlag(c, a, "replay-bytes")) |v| try wq.print("&replay_bytes={d}", .{v});
    const ws_path = wq.buffered();

    const host_header = try std.fmt.allocPrint(c.arena, "{s}:{d}", .{ info.host, info.port });

    // -k / --insecure：跳过证书主机名校验（仅 wss:// 生效；自签证书调试用）
    const insecure = a.has("insecure") or hasShortFlag(a, "-k");
    // 启用了 SANDBOX_KEY 的部署：WS 升级请求也要带鉴权头，否则 401
    const extra_headers = if (c.key) |k|
        try std.fmt.allocPrint(c.arena, "X-API-KEY: {s}\r\n", .{k})
    else
        null;
    var conn = ws.dial(c.io, info.host, info.port, ws_path, host_header, .{
        .tls = info.tls,
        .insecure = insecure,
        .extra_headers = extra_headers,
    }) catch |e| {
        try c.out.print("WebSocket 连接失败: {t}\n", .{e});
        return e;
    };
    std.debug.print("[ws] connected, path={s}\n", .{ws_path});

    // 发送时机：等服务端发出 ready 之后再发，否则会被直接断开
    var pending_send: ?[]const u8 = a.get("send");

    var max_msgs: usize = 5;
    if (a.get("max")) |v| {
        max_msgs = std.fmt.parseInt(usize, v, 10) catch 5;
    }

    var got: usize = 0;
    var warned_cont = false;
    while (got < max_msgs) {
        const frame = conn.readFrame() catch |e| {
            if (e == error.ConnectionClosed) break;
            try c.err.print("读取帧失败: {t}\n", .{e});
            break;
        };
        switch (frame.opcode) {
            ws.OP_CLOSE => break,
            ws.OP_PING => try conn.sendFrame(ws.OP_PONG, frame.payload),
            ws.OP_TEXT => {
                if (a.has("raw")) {
                    try c.out.print("[TEXT {d}] {s}\n", .{ frame.payload.len, frame.payload });
                } else if (std.json.parseFromSlice(std.json.Value, c.arena, frame.payload, .{})) |parsed| {
                    // 有 data 就输出（自动反转义）；否则输出 [type] 便于观察握手阶段
                    var printed = false;
                    if (parsed.value == .object) {
                        if (parsed.value.object.get("data")) |d| {
                            if (d == .string) {
                                try c.out.print("{s}", .{d.string});
                                printed = true;
                            }
                        }
                        if (!printed) {
                            if (parsed.value.object.get("type")) |t| {
                                if (t == .string) {
                                    try c.out.print("[{s}]\n", .{t.string});
                                    printed = true;
                                }
                            }
                        }
                    }
                    if (!printed) try c.out.print("[{s}]\n", .{frame.payload});
                } else |_| {
                    try c.out.print("[{s}]\n", .{frame.payload});
                }
                try c.out.flush();
                got += 1;
                if (pending_send != null and std.mem.indexOf(u8, frame.payload, "\"ready\"") != null) {
                    const line = try std.fmt.allocPrint(c.arena, "{{\"type\":\"input\",\"data\":\"{s}\"}}", .{try util.jsonEscape(c.arena, pending_send.?)});
                    conn.sendText(line) catch |e| {
                        try c.out.print("发送失败: {t}\n", .{e});
                        return e;
                    };
                    pending_send = null;
                }
            },
            ws.OP_BINARY => {
                try c.out.print("{s}", .{frame.payload});
                try c.out.flush();
                got += 1;
            },
            ws.OP_CONT => {
                // 分片续帧尚未重组（独立改造）：至少提示一次，不静默丢终端输出
                if (!warned_cont) {
                    warned_cont = true;
                    try c.err.print("[pty-ws] 收到分片续帧（opcode 0x0），本实现不重组分片，输出可能缺段；可用 pty-screen 对照\n", .{});
                }
            },
            else => {},
        }
    }
    try c.out.print("\n", .{});

    // 礼貌关闭：发 close 帧再断开。否则服务端会保留半开连接，
    // 导致"下一次附着无响应"（这正是之前 --send 时序问题的真因）。
    conn.sendFrame(ws.OP_CLOSE, "") catch {};
    conn.close();
}

/// 从 {"type":...,"data":"..."} 里取 data（不依赖完整 JSON 解析）。
fn extractJSONData(arena: std.mem.Allocator, payload: []const u8) ?[]const u8 {
    _ = arena;
    const pat = "\"data\":\"";
    const start = std.mem.indexOf(u8, payload, pat) orelse return null;
    const s0 = start + pat.len;
    var i = s0;
    while (i < payload.len) : (i += 1) {
        if (payload[i] == '\\') {
            i += 1;
            continue;
        }
        if (payload[i] == '"') break;
    }
    if (i >= payload.len) return null;
    return payload[s0..i];
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// 短选项 `-k`：现有 Args 解析只把 `--x` 收进 flags，`-k` 会落在 pos。
fn hasShortFlag(a: util.Args, flag: []const u8) bool {
    for (a.pos) |p| {
        if (std.mem.eql(u8, p, flag)) return true;
    }
    return false;
}

pub fn dispatch(c: *Ctx, cmd: []const u8, argv: []const []const u8) !bool {
    const a = try util.parse(c.arena, argv);
    if (eq(cmd, "pty-new")) {
        try cmdNew(c, a);
        return true;
    }
    if (eq(cmd, "pty-ls")) {
        try cmdGet(c, "/v2/pty/sessions");
        return true;
    }
    if (eq(cmd, "pty-info")) {
        const id = try idArg(c, a);
        try cmdGet(c, try std.fmt.allocPrint(c.arena, "/v2/pty/sessions/{s}", .{try util.urlEncode(c.arena, id)}));
        return true;
    }
    if (eq(cmd, "pty")) {
        _ = try idArg(c, a);
        try cmdExec(c, a);
        return true;
    }
    if (eq(cmd, "pty-screen")) {
        const id = try idArg(c, a);
        try cmdGet(c, try std.fmt.allocPrint(c.arena, "/v2/pty/sessions/{s}/screen", .{try util.urlEncode(c.arena, id)}));
        return true;
    }
    if (eq(cmd, "pty-input")) {
        const id = try idArg(c, a);
        const text = a.at(1) orelse "";
        var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 64 << 10));
        try w.print("{{\"input\":\"{s}\",\"press_enter\":{s}}}", .{
            try util.jsonEscape(c.arena, text),
            if (a.has("enter")) "true" else "false",
        });
        try cmdSend(c, try std.fmt.allocPrint(c.arena, "/v2/pty/sessions/{s}/input", .{try util.urlEncode(c.arena, id)}), w.buffered(), .POST);
        return true;
    }
    if (eq(cmd, "pty-signal")) {
        const id = try idArg(c, a);
        const sig = a.get("signal") orelse (a.at(1) orelse "SIGINT");
        const body = try std.fmt.allocPrint(c.arena, "{{\"signal\":\"{s}\"}}", .{try util.jsonEscape(c.arena, sig)});
        try cmdSend(c, try std.fmt.allocPrint(c.arena, "/v2/pty/sessions/{s}/signal", .{try util.urlEncode(c.arena, id)}), body, .POST);
        return true;
    }
    if (eq(cmd, "pty-resize")) {
        const id = try idArg(c, a);
        var w = std.Io.Writer.fixed(try c.arena.alloc(u8, 4096));
        try w.print("{{", .{});
        var first = true;
        if (try util.intFlag(c, a, "cols")) |v| {
            try w.print("\"cols\":{d}", .{v});
            first = false;
        }
        if (try util.intFlag(c, a, "rows")) |v| {
            if (!first) try w.print(",", .{});
            try w.print("\"rows\":{d}", .{v});
            first = false;
        }
        if (try util.intFlag(c, a, "no-change-timeout")) |v| {
            if (!first) try w.print(",", .{});
            try w.print("\"no_change_timeout\":{d}", .{v});
        }
        try w.print("}}", .{});
        try cmdSend(c, try std.fmt.allocPrint(c.arena, "/v2/pty/sessions/{s}", .{try util.urlEncode(c.arena, id)}), w.buffered(), .PATCH);
        return true;
    }
    if (eq(cmd, "pty-rm")) {
        const id = try idArg(c, a);
        const buf = try c.arena.alloc(u8, BUF);
        const res = try httpc.del(c.client, try c.url(try std.fmt.allocPrint(c.arena, "/v2/pty/sessions/{s}", .{try util.urlEncode(c.arena, id)})), try auth(c), buf);
        try util.checkResp(c, res);
        try out(c, res);
        return true;
    }
    if (eq(cmd, "pty-ws") or eq(cmd, "pty-ws-anon")) {
        try cmdPtyWs(c, eq(cmd, "pty-ws-anon"), a);
        return true;
    }
    return false;
}
