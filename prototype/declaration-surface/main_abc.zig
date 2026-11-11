//! PROTOTYPE, throwaway. Run: zig run main_abc.zig
//! Shapes A, B and C lower to the same model; the derivations cannot tell them apart.
const std = @import("std");
const core = @import("core.zig");
const a = @import("domain_a.zig");
const b = @import("domain_b.zig");
const c = @import("domain_c.zig");

pub fn main(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    const out = &fw.interface;

    try out.writeAll("== A: comptime data literals ==\n");
    try core.describe(out, a.domain);
    try out.writeAll("\n== B: annotated struct types ==\n");
    try core.describe(out, b.domain);
    try out.writeAll("\n== C: builder functions ==\n");
    try core.describe(out, c.domain);
    try out.flush();
}
