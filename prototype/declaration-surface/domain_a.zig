//! PROTOTYPE, throwaway. The blog domain in shape A: comptime data literals.
const zava = @import("shape_a.zig");

pub const Author = zava.Resource(.{
    .name = "author",
    .table = "authors",
    .attributes = &.{
        .{ .name = "id", .type = i64, .primary_key = true, .generated = true },
        .{ .name = "email", .type = []const u8 },
        .{ .name = "name", .type = []const u8 },
    },
    .relationships = &.{
        .{ .name = "posts", .kind = .has_many, .destination = "post", .key = "author_id" },
    },
    .actions = &.{
        .{ .name = "register", .kind = .create, .accept = &.{ "email", "name" } },
        .{ .name = "by_email", .kind = .read, .accept = &.{"email"} },
    },
});

pub const Post = zava.Resource(.{
    .name = "post",
    .table = "posts",
    .attributes = &.{
        .{ .name = "id", .type = i64, .primary_key = true, .generated = true },
        .{ .name = "author_id", .type = i64 },
        .{ .name = "title", .type = []const u8 },
        .{ .name = "body", .type = ?[]const u8 },
        .{ .name = "published", .type = bool },
    },
    .relationships = &.{
        .{ .name = "author", .kind = .belongs_to, .destination = "author", .key = "author_id" },
    },
    .actions = &.{
        .{ .name = "draft", .kind = .create, .accept = &.{ "author_id", "title", "body" } },
        .{ .name = "publish", .kind = .update, .accept = &.{"published"} },
        .{ .name = "by_author", .kind = .read, .accept = &.{"author_id"} },
    },
});

pub const domain = zava.Domain(.{ Author, Post });

comptime {
    _ = domain.models;
}
