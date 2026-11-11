//! Variant A: ADR 0001 as prototyped. `zava.Options(@This())` is a generic
//! function returning a source-written struct; attribute names are
//! `std.meta.FieldEnum(T)`, the attributes block is a comptime-built struct
//! keyed by field name, and the hook is `std.meta.DeclEnum(T)`.
const zava = @import("zava.zig");

pub const Author = struct {
    id: i64,
    email: []const u8,
    name: []const u8,

    pub const resource: zava.Options(@This()) = .{
        .table = "authors",
        .primary_key = .id,
        .actions = &.{
            .{ .name = "register", .kind = .create, .accept = &.{ .email, .name }, .after = .welcome },
            .{ .name = "rename", .accept = &.{.name} },
        },
        .attributes = .{
            .email = .{ .unique = true, .column = "email_address" },
        },
    };

    pub fn welcome(self: *Author) void {
        self.name = "Welcome";
    }
};

pub const Post = struct {
    id: i64,
    author_id: i64,
    title: []const u8,
    body: ?[]const u8,
    published: bool,

    pub const resource: zava.Options(@This()) = .{
        .table = "posts",
        .primary_key = .id,
        .actions = &.{
            .{ .name = "draft", .kind = .create, .accept = &.{ .author_id, .title }, .after = .stamp },
            .{ .name = "publish", .accept = &.{.published} },
        },
        .attributes = .{
            .title = .{ .column = "headline" },
        },
    };

    pub fn stamp(self: *Post) void {
        self.published = false;
    }
};

test {
    _ = Author.resource;
    _ = Post.resource;
}
