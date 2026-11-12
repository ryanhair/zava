//! PROTOTYPE, throwaway. What the developer writes. The same filter is spelled three ways.
const zava = @import("zava.zig");

pub const Status = enum { draft, published };

pub const Author = struct {
    id: i64,
    name: []const u8,

    pub const resource = zava.Options(@This()){ .name = "author", .table = "authors" };
};

pub const Comment = struct {
    id: i64,
    post_id: i64,
    flagged: bool,

    pub const resource = zava.Options(@This()){ .name = "comment", .table = "comments" };
};

pub const Post = struct {
    id: i64,
    author_id: i64,
    title: []const u8,
    status: Status,
    views: i64,
    likes: i64,
    featured: bool,

    const p = zava.of(@This()); // spelling B needs a handle

    pub const resource = zava.Options(@This()){
        .name = "post",
        .table = "posts",
        .relationships = &.{
            .{ .name = "author", .kind = .belongs_to, .destination = Author, .source_attribute = .author_id, .destination_attribute = "id" },
            .{ .name = "comments", .kind = .has_many, .destination = Comment, .source_attribute = .id, .destination_attribute = "post_id" },
        },
        .calculations = &.{
            // An expression is the body of a calculation.
            .calc("popularity", i64, .add(.attr(.views), .attr(.likes))),
        },
        .actions = &.{
            // ---- the same filter, three spellings
            .{
                .name = "popular_a",
                .arguments = &.{.{ .name = "min_views", .type = i64 }},
                .filter = .all(&.{
                    .eq(.status, .value(.published)),
                    .gt(.views, .arg(.min_views)),
                }),
            },
            .{
                .name = "popular_b",
                .arguments = &.{.{ .name = "min_views", .type = i64 }},
                .filter = p.attr(.status).eq(.value(.published)).andAlso(p.attr(.views).gt(.arg(.min_views))),
            },
            .{
                .name = "popular_c",
                .arguments = &.{.{ .name = "min_views", .type = i64 }},
                .filter = .parse("status == 'published' and views > $min_views"),
            },

            // ---- a calculation inside an expression, and two relationships crossed
            .{
                .name = "trending_a",
                .arguments = &.{.{ .name = "author_name", .type = []const u8 }},
                .filter = .all(&.{
                    .cmp(i64, .gt, .calc(.popularity), .value(100)),
                    .not(.exists(Comment, .comments, .eq(.flagged, .value(true)))),
                    .cmp([]const u8, .eq, .related(Author, .author, .attr(.name)), .arg(.author_name)),
                }),
            },
            .{
                .name = "trending_b",
                .arguments = &.{.{ .name = "author_name", .type = []const u8 }},
                .filter = p.calc(i64, .popularity).gt(.value(100))
                    .andAlso(.not(.exists(Comment, .comments, zava.of(Comment).attr(.flagged).eq(.value(true)))))
                    .andAlso(.cmp([]const u8, .eq, .related(Author, .author, .attr(.name)), .arg(.author_name))),
            },
            .{
                .name = "trending_c",
                .arguments = &.{.{ .name = "author_name", .type = []const u8 }},
                .filter = .parse("popularity > 100 and not exists(comments, flagged == true) and author.name == $author_name"),
            },

            // ---- an expression in a change: an atomic update
            .{ .name = "view", .kind = .update, .set = &.{.to(.views, .add(.attr(.views), .value(1)))} },
        },
    };
};

pub const resources = .{ Author, Comment, Post };
