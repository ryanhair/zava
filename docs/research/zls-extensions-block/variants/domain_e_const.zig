//! Spelling e: the entry is its own constant annotated through a local alias,
//! `const Pg = postgres.Options(@This()); const pg: Pg = .{ ... };`, and the block names it.
//! Otherwise prototype/extension-mechanism/domain.zig.
const zava = @import("zava");
const postgres = @import("postgres");

pub const Author = struct {
    id: i64,
    email: []const u8,
    name: []const u8,

    const Pg = postgres.Options(@This());
    const pg: Pg = .{
        .table = "authors",
        .attributes = .{ .email = .{ .column = "email_address" } },
    };

    pub const resource = zava.Options(@This()){
        .name = "author",
        .primary_key = .id,
        .attributes = .{ .email = .{ .unique = true } },
        .actions = &.{
            .{ .name = "register", .kind = .create, .accept = &.{ .email, .name } },
            .{ .name = "by_email", .kind = .read, .accept = &.{.email} },
        },
        .extensions = .{ .postgres = pg },
    };
};

pub const Post = struct {
    id: i64,
    author_id: i64,
    title: []const u8,
    body: ?[]const u8,

    const Pg = postgres.Options(@This());
    const pg: Pg = .{
        .table = "posts",
    };

    pub const resource = zava.Options(@This()){
        .name = "post",
        .primary_key = .id,
        .actions = &.{.{ .name = "draft", .kind = .create, .accept = &.{ .author_id, .title, .body } }},
        .extensions = .{ .postgres = pg },
    };
};

/// Not persisted: no postgres entry.
pub const Ping = struct {
    id: i64,
    pub const resource = zava.Options(@This()){ .name = "ping", .primary_key = .id };
};

pub const resources = .{ Author, Post, Ping };
pub const extensions = .{postgres};
