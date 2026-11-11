//! PROTOTYPE probe. Can shape A (or C) point at the destination by type instead of by string?
//! Author and Post are both results of a comptime call, and each names the other.
const core = @import("core.zig");
const zava = @import("shape_a.zig");

pub const Author = zava.Resource(.{
    .name = "author",
    .table = "authors",
    .attributes = &.{.{ .name = "id", .type = i64, .primary_key = true }},
    .relationships = &.{.{ .name = "posts", .kind = .has_many, .destination_type = Post, .key = "author_id" }},
});

pub const Post = zava.Resource(.{
    .name = "post",
    .table = "posts",
    .attributes = &.{ .{ .name = "id", .type = i64, .primary_key = true }, .{ .name = "author_id", .type = i64 } },
    .relationships = &.{.{ .name = "author", .kind = .belongs_to, .destination_type = Author, .key = "author_id" }},
});

comptime {
    _ = Author.model;
}
