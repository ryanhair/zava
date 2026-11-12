//! PROTOTYPE probe. Can `exists` find the destination from the relationship list of the
//! declaration it is written inside, instead of being told the destination type?
const std = @import("std");
fn Dest(comptime R: type, comptime rel: @EnumLiteral()) type {
    for (R.resource.relationships) |r| if (std.mem.eql(u8, r.name, @tagName(rel))) return r.destination;
    @compileError("no relationship " ++ @tagName(rel));
}
fn Pred(comptime R: type) type {
    return struct {
        n: u8,
        pub fn flag(comptime a: std.meta.FieldEnum(R)) @This() { _ = a; return .{ .n = 1 }; }
        pub fn exists(comptime rel: @EnumLiteral(), where: Pred(Dest(R, rel))) @This() { return .{ .n = where.n + 1 }; }
    };
}
fn Options(comptime R: type) type {
    return struct { relationships: []const struct { name: []const u8, destination: type }, filter: ?Pred(R) = null };
}
const Comment = struct { flagged: bool };
const Post = struct {
    id: i64,
    pub const resource: Options(@This()) = .{
        .relationships = &.{.{ .name = "comments", .destination = Comment }},
        .filter = if (@import("builtin").is_test) null else .exists(.comments, .flag(.flagged)),
    };
};
pub fn main() void {
    // Outside the declaration the same call is fine:
    const ok: Pred(Post) = .exists(.comments, .flag(.flagged));
    std.debug.print("{} {}\n", .{ ok.n, Post.resource.filter.?.n });
}
