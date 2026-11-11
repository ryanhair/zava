//! Variant E: the typing of D (developer-written `Field` and `Hook` enums), with
//! the declaration flattened so that every literal sits directly on a
//! declaration annotated with a local alias. Actions and attribute entries are
//! separate constants; `resource` lists them by name.
const zava = @import("zava.zig");

pub const Author = struct {
    id: i64,
    email: []const u8,
    name: []const u8,

    pub const Field = enum { id, email, name };
    pub const Hook = enum { welcome };
    const Options = zava.OptionsList(@This(), Field, Hook);
    const Action = zava.ActionL(Field, Hook);
    const Attr = zava.AttrEntry(Field);

    const register: Action = .{ .name = "register", .kind = .create, .accept = &.{ .email, .name }, .after = .welcome };
    const rename: Action = .{ .name = "rename", .accept = &[_]Field{.name} };
    const email_options: Attr = .{ .field = .email, .unique = true, .column = "email_address" };

    pub const resource: Options = .{
        .table = "authors",
        .primary_key = .id,
        .actions = &.{ register, rename },
        .attributes = &.{email_options},
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
    const Action = zava.ActionL(Field, Hook);
    const Attr = zava.AttrEntry(Field);

    const draft: Action = .{ .name = "draft", .kind = .create, .accept = &.{ .author_id, .title }, .after = .stamp };
    const publish: Action = .{ .name = "publish", .accept = &[_]Field{.published} };
    const title_options: Attr = .{ .field = .title, .column = "headline" };

    pub const resource: Options = .{
        .table = "posts",
        .primary_key = .id,
        .actions = &.{ draft, publish },
        .attributes = &.{title_options},
    };

    pub fn stamp(self: *Post) void {
        self.published = false;
    }
};

test {
    _ = Author.resource;
    _ = Post.resource;
}
