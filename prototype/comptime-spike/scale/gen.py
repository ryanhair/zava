#!/usr/bin/env python3
"""PROTOTYPE. Emit a model of N resources x 20 attributes x 2 actions, two ways:
comptime_N.zig derives everything through zava.zig; handwritten_N.zig is what a
code generator would emit (plain structs, literal SQL, same JSON handler body)."""
import sys
n = int(sys.argv[1]); A = int(sys.argv[2]) if len(sys.argv) > 2 else 20
types = ["[]const u8", "?i32", "bool", "i64"]
sqlt = {"[]const u8": "text not null", "?i32": "integer", "bool": "boolean not null", "i64": "bigint not null"}
cols = [(f"col{j}", types[j % 4]) for j in range(A)]
allcols = ", ".join(["id"] + [c for c, _ in cols])
main_c, main_h = [], []
c = ['const std = @import("std");', 'const zava = @import("zava");', ""]
h = ['const std = @import("std");', ""]
for i in range(n):
    c.append(f'const R{i} = zava.Resource(.{{ .name = "r{i}", .table = "r{i}s", .attributes = &.{{')
    c.append('    .{ .name = "id", .type = i64, .primary_key = true, .generated = true },')
    for name, t in cols:
        c.append(f'    .{{ .name = "{name}", .type = {t} }},')
    acc = ", ".join(f'"{name}"' for name, _ in cols)
    c.append(f'}}, .actions = &.{{ .{{ .name = "create", .kind = .create, .accept = &.{{ {acc} }} }}, .{{ .name = "by_col0", .kind = .read, .accept = &.{{"col0"}} }} }} }});')
    main_c.append(f'    try R{i}.handle(.create, arena, body, out);\n    try R{i}.handle(.by_col0, arena, body, out);\n    try out.writeAll(R{i}.create_table_sql);')

    fields = "".join(f" {name}: {t}," for name, t in cols)
    h.append(f"const R{i} = struct {{")
    h.append(f"    pub const Record = struct {{ id: i64,{fields} }};")
    h.append(f"    pub const CreateInput = struct {{{fields} }};")
    h.append("    pub const ByCol0Input = struct { col0: []const u8 };")
    ct = ", ".join(["id bigint not null generated always as identity primary key"] + [f"{name} {sqlt[t]}" for name, t in cols])
    h.append(f'    pub const create_table_sql = "create table r{i}s ({ct})";')
    ins = ", ".join(name for name, _ in cols); ps = ", ".join(f"${k+1}" for k in range(A))
    h.append(f'    pub const create_sql = "insert into r{i}s ({ins}) values ({ps}) returning {allcols}";')
    h.append(f'    pub const by_col0_sql = "select {allcols} from r{i}s where col0 = $1";')
    for fn, In, sql in (("create", "CreateInput", "create_sql"), ("byCol0", "ByCol0Input", "by_col0_sql")):
        h.append(f"    pub fn {fn}(arena: std.mem.Allocator, body: []const u8, out: *std.Io.Writer) !void {{")
        h.append(f"        const input = std.json.parseFromSliceLeaky({In}, arena, body, .{{}}) catch |err| {{")
        h.append('            try out.print("{{\\"error\\":\\"{s}\\"}}\\n", .{@errorName(err)});')
        h.append("            return;\n        };")
        h.append("        var record: Record = undefined;\n        record.id = 1;")
        for name, t in cols:
            if In == "CreateInput" or name == "col0":
                h.append(f"        record.{name} = input.{name};")
            else:
                dflt = {"[]const u8": '"stub"', "?i32": "null", "bool": "false", "i64": "1"}[t]
                h.append(f"        record.{name} = {dflt};")
        h.append(f'        try out.print("-- {{s}}\\n", .{{{sql}}});')
        h.append("        try std.json.Stringify.value(record, .{}, out);")
        h.append('        try out.writeAll("\\n");\n    }')
    h.append("};")
    main_h.append(f'    try R{i}.create(arena, body, out);\n    try R{i}.byCol0(arena, body, out);\n    try out.writeAll(R{i}.create_table_sql);')
head = """
pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    const out = &fw.interface;
    const arena = init.arena.allocator();
    const body = "{}";
"""
for name, lines, m in (("comptime", c, main_c), ("handwritten", h, main_h)):
    open(f"{name}_{n}.zig", "w").write("\n".join(lines) + head + "\n".join(m) + "\n    try out.flush();\n}\n")
