//! PROTOTYPE, throwaway. Prints the lowered model: the three shapes give the same action.
const std = @import("std");
const zava = @import("zava.zig");
const domain = @import("domain.zig");

const model = zava.model(domain.resources);

pub fn main() void {
    for (model.resources) |r| for (r.actions) |a| {
        std.debug.print("{s}.{s}\n  arguments  ", .{ r.name, a.name });
        for (a.arguments) |g| std.debug.print("{s}: {s} (min {?d})  ", .{ g.name, @tagName(g.kind), g.min });
        std.debug.print("\n  filter     ", .{});
        zava.dump(a.filter.?);
    };
}
