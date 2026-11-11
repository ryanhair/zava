const std = @import("std");
const zava = @import("zava");

const User = zava.Resource(.{
    .name = "user",
    .table = "users",
    .attributes = &.{
        .{ .name = "id", .type = i64, .primary_key = true, .generatd = true },
        .{ .name = "email", .type = []const u8 },
    },
    .actions = &.{
        .{ .name = "register", .kind = .create, .accept = &.{"email"} },
    },
});

pub fn main() void {
    std.debug.print("{s}\n", .{User.sql(.register)});
}
