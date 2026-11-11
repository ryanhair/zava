const std = @import("std");
const zava = @import("zava");
const domain = @import("domain");

pub fn main(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    const out = &fw.interface;
    try out.writeAll("//! GENERATED. Do not edit.\nconst zava = @import(\"zava\");\nconst domain = @import(\"domain\");\n");
    inline for (domain.resources) |R| {
        try out.print("\npub const {s} = struct {{\n", .{R.res_name});
        inline for (R.actions) |a| {
            const shape = comptime zava.inputShape(R, a.name);
            try out.print("    pub const {s} = struct {{\n", .{shape.name});
            for (shape.field_names, shape.field_types) |n, t| try out.print("        {s}: {s},\n", .{ n, t });
            try out.print("    }};\n\n    /// Runs the `{s}` action on `{s}`.\n    /// SQL: `{s}`\n", .{ a.name, R.res_name, comptime zava.sql(R, a.name) });
            try out.print("    pub fn {s}(base: domain.{s}, input: {s}) domain.{s} {{\n        return zava.run(domain.{s}, \"{s}\", base, input);\n    }}\n\n", .{ a.name, R.res_name, shape.name, R.res_name, R.res_name, a.name });
        }
        try out.writeAll("};\n");
    }
    try out.flush();
}
