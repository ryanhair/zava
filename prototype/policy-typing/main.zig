const std = @import("std");
const zava = @import("zava");
const d = @import("domain");
pub fn main() void {
    _ = d.touch;
    std.debug.print("post policies {}, first filter {} nodes, author policies {}\n", .{ zava.policies(d.Post).len, zava.policies(d.Post)[0].filter.?.n, zava.policies(d.Author).len });
    std.debug.print("post filter {} nodes, comment filter {} nodes, author rels {}, hasDecl(hidden)={}\n", .{
        d.Post.resource.actions[0].filter.?.n, d.Comment.resource.actions[0].filter.?.n, zava.count(d.Author), @hasDecl(d.Post, "hidden"),
    });
}
