const std = @import("std");
const api = @import("api");
pub fn main() void {
    const a = api.Author.register(.{ .id = 1, .email = "", .name = "" }, .{ .email = "a@b.c", .name = "ann" });
    std.debug.print("{s} | {s}\n", .{ a.email, a.name });
}
