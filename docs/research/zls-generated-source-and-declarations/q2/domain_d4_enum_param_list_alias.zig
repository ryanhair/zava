//! Variant D4: the typing of D, annotated through an alias:
//! `const Options = zava.OptionsList(@This(), Field, Hook); pub const resource: Options = .{ ... };`.
const zava = @import("zava.zig");

pub const Author = struct {
    id: i64,
    email: []const u8,
    name: []const u8,

    pub const Field = enum { id, email, name };
    pub const Hook = enum { welcome };

    const Options = zava.OptionsList(@This(), Field, Hook);
    pub const resource: Options = .{
        .table = "authors",
        .primary_key = .id,
        .actions = &.{
            .{ .name = "register", .kind = .create, .accept = &.{ .email, .name }, .after = .welcome },
            .{ .name = "rename", .accept = &.{.name} },
        },
        .attributes = &.{
            .{ .field = .email, .unique = true, .column = "email_address" },
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

    pub const Field = enum { id, author_id, title, body, published };
    pub const Hook = enum { stamp };

    const Options = zava.OptionsList(@This(), Field, Hook);
    pub const resource: Options = .{
        .table = "posts",
        .primary_key = .id,
        .actions = &.{
            .{ .name = "draft", .kind = .create, .accept = &.{ .author_id, .title }, .after = .stamp },
            .{ .name = "publish", .accept = &.{.published} },
        },
        .attributes = &.{
            .{ .field = .title, .column = "headline" },
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
