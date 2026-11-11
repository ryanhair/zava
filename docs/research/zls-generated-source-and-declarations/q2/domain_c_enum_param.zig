//! Variant C: the developer writes `pub const Field = enum { ... }` and passes
//! it in: `zava.OptionsF(@This(), Field)`. The generic parameter is used
//! directly as the type of attribute names. The attributes block is still
//! keyed by field name (`std.enums.EnumFieldStruct`), the hook is still
//! `std.meta.DeclEnum(T)`.
const zava = @import("zava.zig");

pub const Author = struct {
    id: i64,
    email: []const u8,
    name: []const u8,

    pub const Field = enum { id, email, name };

    pub const resource: zava.OptionsF(@This(), Field) = .{
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

    pub const Field = enum { id, author_id, title, body, published };

    pub const resource: zava.OptionsF(@This(), Field) = .{
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
