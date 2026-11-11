#!/usr/bin/env python3
"""PROTOTYPE. Makes one mistake at a time in a copy of the prototype and records where the compiler points."""
import os, re, shutil, subprocess, tempfile
here = os.path.dirname(os.path.abspath(__file__))
M = [  # (who, title, file, old, new)
 ("developer", "1 misspelled extension key", "domain.zig", '.extensions = .{ .postgres = .{ .table = "posts" } }', '.extensions = .{ .postgers = .{ .table = "posts" } }'),
 ("developer", "2 misspelled extension option", "domain.zig", '.{ .table = "posts" }', '.{ .tabel = "posts" }'),
 ("developer", "3 misspelled attribute in the extension's per-attribute block", "domain.zig", '.attributes = .{ .email = .{ .column', '.attributes = .{ .emial = .{ .column'),
 ("developer", "4 wrong value type for an extension option", "domain.zig", '.column = "email_address"', '.column = 5'),
 ("developer", "5 extension's own rule: two attributes, one column", "domain.zig", '.column = "email_address"', '.column = "name"'),
 ("developer", "6 attribute type the extension cannot map", "domain.zig", 'body: ?[]const u8,', 'body: ?f32,'),
 ("developer", "7 extension used but not registered", "domain.zig", 'pub const extensions = .{postgres};', 'pub const extensions = .{};'),
 ("developer", "8 app misuses a described type", "app.zig", '.{ .id = 7 }', '.{ .idd = 7 }'),
 ("developer", "9 app misuses a described enum", "app.zig", 'api.Author.SortBy = .email', 'api.Author.SortBy = .emial'),
 ("extension author", "10 delegate names a function that does not exist", "postgres.zig", '.delegate = .get,', '.delegate = .gett,'),
 ("extension author", "11 reference to a described type that does not exist", "postgres.zig", '.{ .described = "PrimaryKey" }', '.{ .described = "PrimaryKeyy" }'),
 ("extension author", "12 field type with no spelling", "postgres.zig", '.{ .type = Limit }', '.{ .type = struct { count: u32 } }'),
 ("extension author", "13 delegate signature disagrees with the description", "postgres.zig", '.returns = .{ .type = ?R },', '.returns = .{ .type = R },'),
 ("extension author", "14 describes a name the kernel already generates", "postgres.zig", '.name = "get",', '.name = "register",'),
 ("extension author", "15 contract breach: no `lower`", "postgres.zig", 'pub fn lower(', 'pub fn lowerr('),
]
out = []
for who, title, f, old, new in M:
    d = tempfile.mkdtemp()
    for n in os.listdir(here):
        if n.endswith(".zig") or n == "mise.toml": shutil.copy(os.path.join(here, n), d)
    p = os.path.join(d, f); s = open(p).read(); assert old in s, title
    open(p, "w").write(s.replace(old, new, 1))
    r = subprocess.run(["zig", "build", "run"], cwd=d, capture_output=True, text=True).stderr
    lines = r.splitlines()
    keep = []
    for i, l in enumerate(lines):
        if re.search(r": (error|note): ", l) and "lib/std" not in l:
            keep += [l.replace(d + "/", "")] + [x for x in lines[i+1:i+3] if not re.search(r": (error|note): ", x)]
        if l.startswith("referenced by") or len(keep) > 14: break
    step = next((l.strip() for l in lines if "compile exe" in l), "")
    out.append(f"=== [{who}] {title}\n    {f}: `{old}` -> `{new}`\n" + "\n".join(keep) + "\n")
    shutil.rmtree(d)
open(os.path.join(here, "errors.txt"), "w").write("\n".join(out))
print("\n".join(out))
