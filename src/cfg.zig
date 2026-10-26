//! 配置与环境变量。
//!
//! 约定：本仓库不出现任何真实主机名 / IP / 凭据，全部由环境变量注入。
const std = @import("std");

/// 版本号始终跟随上游 aiod（见 scripts/v2-coverage.json 的 source 字段）。
pub const version = "0.9.2";

pub fn getenv(name: [*:0]const u8) ?[]const u8 {
    const p = std.c.getenv(name) orelse return null;
    return std.mem.span(p);
}

/// 沙箱内 aiod 网关地址，形如 https://<gateway-host>/sandbox/<sandboxID>/<port>
pub fn sandboxBase() ?[]const u8 {
    return getenv("SANDBOX_BASE");
}

/// aiod 鉴权 Key（可选）。空串当作未设置 —— 否则会发一个空的 X-API-KEY 头，全部 401。
pub fn sandboxKey() ?[]const u8 {
    const k = getenv("SANDBOX_KEY") orelse return null;
    if (k.len == 0) return null;
    return k;
}

/// 默认单次请求超时（秒），可由 --timeout 覆盖。
pub const default_timeout_s: u32 = 60;
