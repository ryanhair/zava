//! Variant A4: the typing of A (derived enums), annotated through an alias:
//! `const Options = zava.Options(@This()); pub const resource: Options = .{ ... };`.
const zava = @import("zava.zig");

pub const Author = struct {
    id: i64,
    email: []const u8,
    name: []const u8,

    const Options = zava.Options(@This());
    pub const resource: Options = .{
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

    const Options = zava.Options(@This());
    pub const resource: Options = .{
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
