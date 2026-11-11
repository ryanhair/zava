//! PROTOTYPE, throwaway. The blog domain in shape C: builder functions.
const zava = @import("shape_c.zig");

pub const Author = zava.resource("author", "authors")
    .attribute("id", i64, .{ .primary_key = true, .generated = true })
    .attribute("email", []const u8, .{})
    .attribute("name", []const u8, .{})
    .hasMany("posts", "post", "author_id")
    .create("register", &.{ "email", "name" })
    .read("by_email", &.{"email"})
    .build();

pub const Post = zava.resource("post", "posts")
    .attribute("id", i64, .{ .primary_key = true, .generated = true })
    .attribute("author_id", i64, .{})
    .attribute("title", []const u8, .{})
    .attribute("body", ?[]const u8, .{})
    .attribute("published", bool, .{})
    .belongsTo("author", "author", "author_id")
    .create("draft", &.{ "author_id", "title", "body" })
    .update("publish", &.{"published"})
    .read("by_author", &.{"author_id"})
    .build();

pub const domain = zava.Domain(.{ Author, Post });

comptime {
    _ = domain.models;
}
