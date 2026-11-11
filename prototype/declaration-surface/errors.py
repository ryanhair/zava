#!/usr/bin/env python3
"""PROTOTYPE, throwaway. Makes the same seven mistakes in each declaration shape
and records what the compiler says. Run: python3 errors.py > errors.txt"""
import os, subprocess, sys

RECORD_TYPO = {
    "a": "\ncomptime {\n    var r: Author.Record = undefined;\n    r.emial = \"x\";\n}\n",
    "b": "\ncomptime {\n    var r: Author = undefined;\n    r.emial = \"x\";\n}\n",
    "c": "\ncomptime {\n    var r: Author.Record = undefined;\n    r.emial = \"x\";\n}\n",
}

# name -> per-shape (old, new); first occurrence only. None = append RECORD_TYPO.
MISTAKES = [
    ("1 action accepts a misspelled attribute", {
        "a": ('.accept = &.{ "email", "name" }', '.accept = &.{ "emial", "name" }'),
        "b": ('.accept = &.{ .email, .name }', '.accept = &.{ .emial, .name }'),
        "c": ('.create("register", &.{ "email", "name" })', '.create("register", &.{ "emial", "name" })'),
        "d": ('.accept = &.{ "email", "name" }', '.accept = &.{ "emial", "name" }'),
    }),
    ("2 relationship names a resource that does not exist", {
        "a": ('.destination = "post"', '.destination = "psot"'),
        "b": ('zava.hasMany("posts", Post, .author_id)', 'zava.hasMany("posts", Psot, .author_id)'),
        "c": ('.hasMany("posts", "post", "author_id")', '.hasMany("posts", "psot", "author_id")'),
        "d": ('.destination = "post"', '.destination = "psot"'),
    }),
    ("3 has_many key is not an attribute of the destination", {
        "a": ('.destination = "post", .key = "author_id"', '.destination = "post", .key = "writer_id"'),
        "b": ('zava.hasMany("posts", Post, .author_id)', 'zava.hasMany("posts", Post, .writer_id)'),
        "c": ('.hasMany("posts", "post", "author_id")', '.hasMany("posts", "post", "writer_id")'),
        "d": ('.destination = "post", .key = "author_id"', '.destination = "post", .key = "writer_id"'),
    }),
    ("4 duplicate attribute", {
        "a": ('        .{ .name = "name", .type = []const u8 },', '        .{ .name = "name", .type = []const u8 },\n        .{ .name = "email", .type = []const u8 },'),
        "b": ('    name: []const u8,', '    name: []const u8,\n    email: []const u8,'),
        "c": ('    .attribute("name", []const u8, .{})', '    .attribute("name", []const u8, .{})\n    .attribute("email", []const u8, .{})'),
        "d": ('            .{ .name = "name", .type = []const u8 },', '            .{ .name = "name", .type = []const u8 },\n            .{ .name = "email", .type = []const u8 },'),
    }),
    ("5 misspelled option", {
        "a": ('.primary_key = true', '.primry_key = true'),
        "b": ('.primary_key = .id', '.primry_key = .id'),
        "c": ('.primary_key = true', '.primry_key = true'),
        "d": ('.primary_key = true', '.primry_key = true'),
    }),
    ("6 attribute type with no Postgres mapping", {
        "a": ('.{ .name = "name", .type = []const u8 }', '.{ .name = "name", .type = f32 }'),
        "b": ('    name: []const u8,', '    name: f32,'),
        "c": ('.attribute("name", []const u8, .{})', '.attribute("name", f32, .{})'),
        "d": ('.{ .name = "name", .type = []const u8 }', '.{ .name = "name", .type = f32 }'),
    }),
    ("7 application code misspells a record field", {"a": None, "b": None, "c": None, "d": None}),
]

SHAPES = [("a", "data literals"), ("b", "annotated structs"), ("c", "builder functions"), ("d", "build-step generated")]


def zig(*args):
    p = subprocess.run(["zig", *args], capture_output=True, text=True)
    lines = []
    for line in p.stderr.splitlines():
        if line.startswith("referenced by:"):
            break
        lines.append(line.replace(os.path.expanduser("~"), "~"))
    return "\n".join(lines) or "(compiled without error)"


subprocess.run("zig build gen > _generated.zig", shell=True, check=True)
for title, per_shape in MISTAKES:
    print("=" * 100)
    print("MISTAKE " + title)
    print("=" * 100)
    for shape, label in SHAPES:
        src = open(f"domain_{shape}.zig").read()
        err = f"_err_{shape}.zig"
        edit = per_shape[shape]
        if edit is None and shape == "d":
            open(err, "w").write('const g = @import("generated");\ncomptime {\n    var r: g.Author = undefined;\n    r.emial = "x";\n}\n')
            out = zig("build-obj", "-fno-emit-bin", "--dep", "generated", f"-Mroot={err}", "-Mgenerated=_generated.zig")
        else:
            if edit is None:
                src += RECORD_TYPO[shape]
            else:
                assert edit[0] in src, (title, shape)
                src = src.replace(edit[0], edit[1], 1)
            open(err, "w").write(src)
            if shape == "d":
                out = zig("build-exe", "-fno-emit-bin", "--dep", "domain", "-Mroot=gen.zig", f"-Mdomain={err}")
            else:
                out = zig("build-obj", "-fno-emit-bin", err)
        os.remove(err)
        print(f"\n--- {shape.upper()}: {label} ---")
        print(out)
    print()
os.remove("_generated.zig")
