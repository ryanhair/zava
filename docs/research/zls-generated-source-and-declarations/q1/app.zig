const std = @import("std");
const api = @import("api");

pub fn main() void {
    const blank: api.Author.Record = .{ .id = 1, .email = "", .name = "" };
    const a = api.Author.register(blank, .{ .email = "a@b.c", .name = "ann" });
    const b = api.Author.rename(a, .{ .name = "bob" });
    var in: api.Author.RegisterInput = .{ .email = "x", .name = "y" };
    in.name = "z";
    const empty: api.Post.Record = .{ .id = 1, .author_id = 1, .title = "", .body = null, .published = true };
    const p = api.Post.draft(empty, .{ .author_id = 2, .title = "t", .body = null });
    const q = api.Post.publish(p, .{ .published = true });
    std.debug.print("{s} | {s} | {s} | {s} | {}\n", .{ a.email, b.name, in.name, p.title, q.published });
}
