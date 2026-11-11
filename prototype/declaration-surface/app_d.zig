//! PROTOTYPE, throwaway. What consuming shape D's generated module looks like.
const std = @import("std");
const g = @import("generated");

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    const out = &fw.interface;

    try out.writeAll("== D: build-step generated ==\n");
    inline for (.{ g.Author, g.Post }) |R| {
        try out.print("  record type: {s}\n    {s}\n", .{ @typeName(R), R.create_table_sql });
    }
    try out.print("  input type : {s}\n", .{@typeName(g.Post.DraftInput)});
    try out.print("  method call: Post.draft(...)  -> {s}\n", .{g.Post.draft(.{ .author_id = 1, .title = "hi", .body = null })});
    try out.print("  relationship method type: {s}\n", .{@typeName(@TypeOf(g.Post.author))});
    try out.flush();
}
