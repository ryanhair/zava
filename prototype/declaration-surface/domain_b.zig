//! PROTOTYPE, throwaway. The blog domain in shape B: annotated struct types.
const zava = @import("shape_b.zig");

pub const Author = struct {
    id: i64,
    email: []const u8,
    name: []const u8,

    pub const resource: zava.Options(@This()) = .{
        .name = "author",
        .table = "authors",
        .primary_key = .id,
        .generated = &.{.id},
        .relationships = &.{
            zava.hasMany("posts", Post, .author_id),
        },
        .actions = &.{
            .{ .name = "register", .kind = .create, .accept = &.{ .email, .name } },
            .{ .name = "by_email", .kind = .read, .accept = &.{.email} },
        },
    };
};

pub const Post = struct {
    id: i64,
    author_id: i64,
    title: []const u8,
    body: ?[]const u8,
    published: bool,

    pub const resource: zava.Options(@This()) = .{
        .name = "post",
        .table = "posts",
        .primary_key = .id,
        .generated = &.{.id},
        .relationships = &.{
            zava.belongsTo(@This(), "author", Author, .author_id),
        },
        .actions = &.{
            .{ .name = "draft", .kind = .create, .accept = &.{ .author_id, .title, .body } },
            .{ .name = "publish", .kind = .update, .accept = &.{.published} },
            .{ .name = "by_author", .kind = .read, .accept = &.{.author_id} },
        },
    };
};

pub const domain = zava.Domain(.{ Author, Post });

comptime {
    _ = domain.models;
}
