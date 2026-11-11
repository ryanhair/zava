const std = @import("std");
const zava = @import("zava");

const User = zava.Resource(.{
    .name = "user",
    .table = "users",
    .attributes = &.{
        .{ .name = "id", .type = i64, .primary_key = true, .generated = true },
        .{ .name = "email", .type = []const u8 },
    },
    .actions = &.{
        .{ .name = "register", .kind = .create, .accept = &.{"email"} },
    },
});

pub fn main() void {
    const r: User.Record = .{ .id = 1, .email = 5 };
    _ = r;
}
