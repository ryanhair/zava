//! The developer's declaration. Wired into two module graphs by build.zig:
//! once against an empty stub of `api` (so the generator can compile) and once
//! against the real generated `api`.
const zava = @import("zava");
const api = @import("api");

pub const Author = struct {
    id: i64,
    email: []const u8,
    name: []const u8,

    pub const res_name = "Author";
    pub const table = "authors";
    pub const actions: []const zava.Action(Author) = &.{
        .{ .name = "register", .accept = &.{ .email, .name }, .after = .welcome },
        .{ .name = "rename", .accept = &.{.name} },
    };

    /// Hook: typed on a generated type, body calls the generated API.
    pub fn welcome(self: *Author, input: api.Author.RegisterInput) void {
        self.* = api.Author.rename(self.*, .{ .name = "Welcome" });
        _ = input.email;
    }
};

pub const Post = struct {
    id: i64,
    author_id: i64,
    title: []const u8,
    body: ?[]const u8,
    published: bool,

    pub const res_name = "Post";
    pub const table = "posts";
    pub const actions: []const zava.Action(Post) = &.{
        .{ .name = "draft", .accept = &.{ .author_id, .title, .body }, .after = .stamp },
        .{ .name = "publish", .accept = &.{.published} },
    };

    /// Hook: typed on a generated type.
    pub fn stamp(self: *Post, input: api.Post.DraftInput) void {
        self.published = false;
        _ = input.title;
    }
};

pub const resources = .{ Author, Post };
