//! Generated-style surface: what a build step would emit as plain Zig source
//! for the same domain as derived.zig. No comptime type construction.
const std = @import("std");

pub const Error = error{ Invalid, Forbidden, Conflict };

pub const Author = struct {
    id: i64,
    email: []const u8,
    name: []const u8,

    pub const RegisterInput = struct {
        email: []const u8,
        name: []const u8,
    };
    pub fn register(input: RegisterInput) Error!Author {
        return .{ .id = 1, .email = input.email, .name = input.name };
    }

    pub const RenameInput = struct {
        name: []const u8,
    };
    pub fn rename(input: RenameInput) Error!Author {
        return .{ .id = 1, .email = "", .name = input.name };
    }
};

pub const Post = struct {
    id: i64,
    author_id: i64,
    title: []const u8,
    body: ?[]const u8,
    published: bool,

    pub const DraftInput = struct {
        author_id: i64,
        title: []const u8,
        body: ?[]const u8,
    };
    pub fn draft(input: DraftInput) Error!Post {
        return .{ .id = 1, .author_id = input.author_id, .title = input.title, .body = input.body, .published = false };
    }

    pub const PublishInput = struct {
        published: bool,
    };
    pub fn publish(input: PublishInput) Error!Post {
        return .{ .id = 1, .author_id = 1, .title = "", .body = null, .published = input.published };
    }
};

// user-written, fully typed hook
fn normalize(input: *Author.RegisterInput) void {
    input.name = "Ann";
}

// Control: the record struct as a parameter type.
fn control(author: Author) []const u8 {
    return author.name;
}

pub fn main() !void {
    var in: Author.RegisterInput = .{ .email = "a@b.c", .name = "ann" };
    normalize(&in);
    const a = try Author.register(in);
    _ = in.email;
    _ = a.email;
    const lit = try Author.register(.{ .email = "x", .name = "y" });
    _ = lit;

    const post_in: Post.PublishInput = .{ .published = true };
    const p = try Post.publish(post_in);
    _ = p.title;
    const d = try Post.draft(.{ .author_id = 1, .title = "t", .body = null });
    _ = d;

    _ = control(a);
    std.debug.print("{s} {s}\n", .{ a.email, a.name });
}
