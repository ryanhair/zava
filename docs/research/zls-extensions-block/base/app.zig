const std = @import("std");
const api = @import("api");
const zava = @import("zava");
const postgres = @import("postgres");

pub fn main() void {
    const a = api.Author.register(.{ .email = "a@b.c", .name = "ann" });
    std.debug.print("kernel action:        register -> {s} | {s}\n", .{ a.email, a.name });

    std.debug.print("described function:   Author.get(.{{ .id = 7 }})\n", .{});
    _ = api.Author.get(.{ .id = 7 });

    var sort: api.Author.SortBy = .email;
    _ = &sort;
    std.debug.print("described enum + fn:  {s}\n", .{api.Author.listSql(sort, .{})});

    std.debug.print("\nmodel, read at runtime:\n", .{});
    for (zava.model.resources, zava.allOptions(postgres)) |r, t| {
        std.debug.print("  {s}: pk {s}, {d} attributes, {d} actions, table {s}\n", .{ r.name, r.primary_key, r.attributes.len, r.actions.len, if (t) |x| x.name else "(none)" });
    }
}
