//! PROTOTYPE, throwaway. Run: zig run main.zig
const std = @import("std");
const zava = @import("zava.zig");

const User = zava.Resource(.{
    .name = "user",
    .table = "users",
    .attributes = &.{
        .{ .name = "id", .type = i64, .primary_key = true, .generated = true },
        .{ .name = "email", .type = []const u8 },
        .{ .name = "age", .type = ?i32 },
        .{ .name = "admin", .type = bool },
    },
    .actions = &.{
        .{ .name = "register", .kind = .create, .accept = &.{ "email", "age", "admin" } },
        .{ .name = "by_email", .kind = .read, .accept = &.{"email"} },
    },
});

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    const out = &fw.interface;
    const arena = init.arena.allocator();

    try out.print("Record type name : {s}\n", .{@typeName(User.Record)});
    try out.print("Input type name  : {s}\n", .{@typeName(User.Input(.register))});
    try out.print("Record size      : {d} bytes\n\n", .{@sizeOf(User.Record)});
    try out.print("{s}\n{s}\n{s}\n\n", .{ User.create_table_sql, User.sql(.register), User.sql(.by_email) });

    try out.writeAll("register, good body:\n");
    try User.handle(.register, arena, "{\"email\":\"a@b.c\",\"age\":41,\"admin\":false}", out);
    try out.writeAll("register, age null:\n");
    try User.handle(.register, arena, "{\"email\":\"a@b.c\",\"age\":null,\"admin\":true}", out);
    try out.writeAll("register, missing field:\n");
    try User.handle(.register, arena, "{\"email\":\"a@b.c\"}", out);
    try out.writeAll("register, wrong type:\n");
    try User.handle(.register, arena, "{\"email\":5,\"age\":1,\"admin\":true}", out);
    try out.writeAll("register, unknown field:\n");
    try User.handle(.register, arena, "{\"email\":\"a@b.c\",\"age\":1,\"admin\":true,\"id\":9}", out);
    try out.writeAll("by_email:\n");
    try User.handle(.by_email, arena, "{\"email\":\"a@b.c\"}", out);
    try out.flush();
}
