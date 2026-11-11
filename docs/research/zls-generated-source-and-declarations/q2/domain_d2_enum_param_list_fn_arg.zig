//! Variant D2: the typing of D (developer-written `Field` and `Hook` enums,
//! attributes as a list), but the literal is a function argument:
//! `pub const resource = zava.resourceList(@This(), Field, Hook, .{ ... });`.
const zava = @import("zava.zig");

pub const Author = struct {
    id: i64,
    email: []const u8,
    name: []const u8,

    pub const Field = enum { id, email, name };
    pub const Hook = enum { welcome };

    pub const resource = zava.resourceList(@This(), Field, Hook, .{
        .table = "authors",
        .primary_key = .id,
        .actions = &.{
            .{ .name = "register", .kind = .create, .accept = &.{ .email, .name }, .after = .welcome },
            .{ .name = "rename", .accept = &.{.name} },
        },
        .attributes = &.{
            .{ .field = .email, .unique = true, .column = "email_address" },
        },
    });

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

    pub const Field = enum { id, author_id, title, body, published };
    pub const Hook = enum { stamp };

    pub const resource = zava.resourceList(@This(), Field, Hook, .{
        .table = "posts",
        .primary_key = .id,
        .actions = &.{
            .{ .name = "draft", .kind = .create, .accept = &.{ .author_id, .title }, .after = .stamp },
            .{ .name = "publish", .accept = &.{.published} },
        },
        .attributes = &.{
            .{ .field = .title, .column = "headline" },
        },
    });

    pub fn stamp(self: *Post) void {
        self.published = false;
    }
};

test {
    _ = Author.resource;
    _ = Post.resource;
}
