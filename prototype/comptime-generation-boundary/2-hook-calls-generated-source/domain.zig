const std = @import("std");
const api = @import("api");

pub const Action = struct { name: []const u8, accept: []const std.meta.FieldEnum(Author), after: ?std.meta.DeclEnum(Author) = null };

pub const Author = struct {
    id: i64,
    email: []const u8,
    name: []const u8,

    pub const actions: []const Action = &.{
        .{ .name = "register", .accept = &.{ .email, .name }, .after = .welcome },
        .{ .name = "rename", .accept = &.{.name} },
    };

    /// Hook: signature uses only the record; body calls the generated API.
    pub fn welcome(self: *Author) void {
        const renamed = api.Author.rename(self.*, .{ .name = "Welcome, Ann" });
        self.* = renamed;
    }
};
