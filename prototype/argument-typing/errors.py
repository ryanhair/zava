#!/usr/bin/env python3
"""PROTOTYPE. Makes one mistake at a time in a copy of the prototype and records where the compiler points."""
import os, re, shutil, subprocess, tempfile
here = os.path.dirname(os.path.abspath(__file__))
ARG = ".gt(.views, .arg(.min_views))"          # occurrence 0 is shape 0, occurrence 1 is shape 1
ARG2 = ".gt(.views, .argOf(PopularArguments, .min_views))"
M = [  # (shape, title, old, new, occurrence)
 ("0 current",  "1 argument that does not exist", ARG, ".gt(.views, .arg(.min_view))", 0),
 ("1 function", "1 argument that does not exist", ARG, ".gt(.views, .arg(.min_view))", 1),
 ("2 named",    "1 argument that does not exist", ARG2, ".gt(.views, .argOf(PopularArguments, .min_view))", 0),

 ("0 current",  "2 argument of the wrong type", ARG, ".eq(.title, .arg(.min_views))", 0),
 ("1 function", "2 argument of the wrong type", ARG, ".eq(.title, .arg(.min_views))", 1),
 ("2 named",    "2 argument of the wrong type", ARG2, ".eq(.title, .argOf(PopularArguments, .min_views))", 0),

 ("2 named",    "3 another action's arguments type named", ARG2, ".gt(.views, .argOf(RecentArguments, .min_views))", 0),

 ("0 current",  "4 attribute that does not exist (control: must stay on the token)", ARG, ".gt(.viewz, .arg(.min_views))", 0),
 ("1 function", "4 attribute that does not exist (control: must stay on the token)", ARG, ".gt(.viewz, .arg(.min_views))", 1),

 ("0 current",  "5 misspelled entry field (control)", ".filter = .all(&.{", ".fliter = .all(&.{", 0),
 ("1 function", "5 misspelled entry field (control)", ".filter = .all(&.{", ".fliter = .all(&.{", 1),

 ("0 current",  "6 argument option that does not exist", ".type = i64, .min = 0", ".type = i64, .mni = 0", 0),
 ("1 function", "6 argument option that does not exist", ".min_views = .{ .min = 0 }", ".min_views = .{ .mni = 0 }", 0),
 ("1 function", "7 options given for an argument that does not exist", ".min_views = .{ .min = 0 }", ".min_view = .{ .min = 0 }", 0),

 ("0 current",  "8 argument type that cannot appear in an expression", ".type = i64, .min = 0", ".type = f32, .min = 0", 0),
 ("1 function", "8 argument type that cannot appear in an expression", "struct { min_views: i64 }, .{", "struct { min_views: f32 }, .{", 0),
]
def nth_replace(s, old, new, k):
    i = -1
    for _ in range(k + 1):
        i = s.index(old, i + 1)
    return s[:i] + new + s[i + len(old):]
out = []
for who, title, old, new, k in M:
    d = tempfile.mkdtemp()
    for n in os.listdir(here):
        if n.endswith(".zig") or n == "mise.toml": shutil.copy(os.path.join(here, n), d)
    p = os.path.join(d, "domain.zig"); s = open(p).read()
    open(p, "w").write(nth_replace(s, old, new, k))
    subprocess.run(["mise", "trust", d], capture_output=True)
    r = subprocess.run(["zig", "build-exe", "main.zig", "-fno-emit-bin"], cwd=d, capture_output=True, text=True).stderr
    lines = r.splitlines()
    keep = []
    for i, l in enumerate(lines):
        if re.search(r": (error|note): ", l) and "lib/std" not in l:
            keep += [l.replace(d + "/", "")] + [x for x in lines[i+1:i+3] if not re.search(r": (error|note): ", x)]
        if l.startswith("referenced by") or len(keep) > 14: break
    if not keep: keep = ["(compiled without error)"] + lines[:6]
    out.append(f"=== [shape {who}] {title}\n    `{old}` -> `{new}`\n" + "\n".join(keep) + "\n")
    shutil.rmtree(d)
open(os.path.join(here, "errors.txt"), "w").write("\n".join(out))
print("\n".join(out))
