//! PROTOTYPE, throwaway. Shape D's generator: imports the domain module, checks
//! the whole model while it compiles, then prints ordinary Zig source.
const std = @import("std");
const domain = @import("domain");
const core = domain.zava;

comptime {
    @setEvalBranchQuota(100_000);
    for (domain.resources) |r| core.validateRes(r);
    core.validateDomain(domain.resources);
}

fn pascal(comptime s: []const u8) []const u8 {
    var out: []const u8 = "";
    var up = true;
    for (s) |ch| {
        if (ch == '_') {
            up = true;
            continue;
        }
        out = out ++ [_]u8{if (up) std.ascii.toUpper(ch) else ch};
        up = false;
    }
    return out;
}

pub fn main(init: std.process.Init) !void {
    @setEvalBranchQuota(100_000);
    var buf: [8192]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    const out = &fw.interface;

    try out.writeAll("//! GENERATED from the domain declaration by gen.zig. Do not edit.\n");
    inline for (domain.resources) |r| {
        const Name = comptime pascal(r.name);
        try out.print("\npub const {s} = struct {{\n", .{Name});
        inline for (r.attributes) |a| try out.print("    {s}: {s},\n", .{ a.name, @typeName(a.type) });
        try out.print("\n    pub const table = \"{s}\";\n", .{r.table});
        try out.print("    pub const create_table_sql = \"{s}\";\n", .{comptime core.createTableSql(domain.resources, r)});
        inline for (r.relationships) |rel| {
            const Dest = comptime pascal(rel.destination);
            switch (rel.kind) {
                .has_many => try out.print(
                    "\n    /// has_many {s} (stub)\n    pub fn {s}(self: {s}) []const {s} {{\n        _ = self;\n        return &.{{}};\n    }}\n",
                    .{ rel.name, rel.name, Name, Dest },
                ),
                .belongs_to => try out.print(
                    "\n    /// belongs_to {s} (stub)\n    pub fn {s}(self: {s}) ?{s} {{\n        _ = self;\n        return null;\n    }}\n",
                    .{ rel.name, rel.name, Name, Dest },
                ),
            }
        }
        inline for (r.actions) |act| {
            const In = comptime pascal(act.name) ++ "Input";
            try out.print("\n    pub const {s} = struct {{\n", .{In});
            inline for (act.accept) |name|
                try out.print("        {s}: {s},\n", .{ name, @typeName(core.findAttr(r, name).?.type) });
            try out.print("    }};\n    /// {s} (stub: returns its route)\n", .{comptime core.route(r, act)});
            try out.print("    pub fn {s}(input: {s}) []const u8 {{\n        _ = input;\n        return \"{s}\";\n    }}\n", .{ act.name, In, comptime core.route(r, act) });
        }
        try out.writeAll("};\n");
    }
    try out.flush();
}
