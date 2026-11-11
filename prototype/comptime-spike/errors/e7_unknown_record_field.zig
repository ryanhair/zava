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
    var r: User.Record = undefined;
    r.emial = "x";
}
