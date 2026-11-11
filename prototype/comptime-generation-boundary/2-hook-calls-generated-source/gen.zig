const std = @import("std");
const domain = @import("domain");

pub fn main(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    const out = &fw.interface;
    try out.writeAll("//! GENERATED. Do not edit.\nconst domain = @import(\"domain\");\n\npub const Author = struct {\n");
    inline for (domain.Author.actions) |a| {
        try out.print("    pub const {s}_Input = struct {{\n", .{a.name});
        inline for (a.accept) |f| try out.print("        {s}: {s},\n", .{ @tagName(f), @typeName(@FieldType(domain.Author, @tagName(f))) });
        try out.print("    }};\n    pub fn {s}(base: domain.Author, input: {s}_Input) domain.Author {{\n        var r = base;\n", .{ a.name, a.name });
        inline for (a.accept) |f| try out.print("        r.{s} = input.{s};\n", .{ @tagName(f), @tagName(f) });
        if (a.after) |h| try out.print("        domain.Author.{s}(&r);\n", .{@tagName(h)});
        try out.writeAll("        return r;\n    }\n");
    }
    try out.writeAll("};\n");
    try out.flush();
}
