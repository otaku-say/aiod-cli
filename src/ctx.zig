//! 命令上下文：运行期句柄 + 沙箱地址。
const std = @import("std");

pub const Ctx = struct {
    io: std.Io,
    client: *std.http.Client,
    arena: std.mem.Allocator,
    out: *std.Io.Writer,
    /// 诊断 / 错误输出（stderr）：错误绝不能进 stdout —— `cat /a | tar x` 会把错误 JSON 喂给解包器
    err: *std.Io.Writer,
    /// aiod 网关基址（末尾无斜杠），如 https://<host>/sandbox/<id>/8080
    base: []const u8,
    /// 可空鉴权 Key
    key: ?[]const u8,

    /// 拼完整 URL：`try c.url("/v2/commands")`
    pub fn url(self: *Ctx, path: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena, "{s}{s}", .{ self.base, path });
    }

    /// 带格式化路径：`try c.urlFmt("/v2/commands/{s}", .{id})`
    pub fn urlFmt(self: *Ctx, comptime fmt: []const u8, args: anytype) ![]const u8 {
        const p = try std.fmt.allocPrint(self.arena, fmt, args);
        return std.fmt.allocPrint(self.arena, "{s}{s}", .{ self.base, p });
    }
};

/// 远端退出码 → 本进程退出码（与上游契约一致，两个 CLI 同一套规则）。
///
/// 上游 aiod 的 /v2/commands 与 CubeSandbox SDK 的 CommandResult 都直接给
/// `exit_code: int`，所以 shell 里就该拿到同一个数字：
///   exit_code >= 0 → 原样透传（0 = 成功）
///   exit_code <  0 → 1（上游没给合法 shell 码，通常是 -1 = 被信号杀死）
///   status 为 timed_out → 124（同 timeout(1)），因为它没有可透传的数字
pub fn remoteExit(c: *Ctx, code: ?i64, status: []const u8) noreturn {
    c.out.flush() catch {};
    c.err.flush() catch {};
    if (std.mem.eql(u8, status, "timed_out")) std.process.exit(124);
    const k = code orelse 1;
    std.process.exit(if (k >= 0) @intCast(@min(k, 255)) else 1);
}
