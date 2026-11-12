#!/usr/bin/env python3
"""PROTOTYPE. Makes one mistake at a time in a copy of the prototype and records where the compiler points."""
import os, re, shutil, subprocess, tempfile
here = os.path.dirname(os.path.abspath(__file__))
A_POP = '.eq(.status, .value(.published)),\n                    .gt(.views, .arg(.min_views)),'
B_POP = 'p.attr(.status).eq(.value(.published)).andAlso(p.attr(.views).gt(.arg(.min_views)))'
C_POP = '"status == \'published\' and views > $min_views"'
M = [  # (spelling, title, file, old, new)
 ("A prefix", "1 missing attribute", "domain.zig", A_POP, A_POP.replace(".gt(.views,", ".gt(.viewz,")),
 ("B method", "1 missing attribute", "domain.zig", B_POP, B_POP.replace("p.attr(.views)", "p.attr(.viewz)")),
 ("C string", "1 missing attribute", "domain.zig", C_POP, C_POP.replace("views", "viewz")),

 ("A prefix", "2 literal of the wrong type", "domain.zig", A_POP, A_POP.replace(".arg(.min_views)", '.value("ten")')),
 ("B method", "2 literal of the wrong type", "domain.zig", B_POP, B_POP.replace(".arg(.min_views)", '.value("ten")')),
 ("C string", "2 literal of the wrong type", "domain.zig", C_POP, C_POP.replace("$min_views", "'ten'")),

 ("A prefix", "3 enum value that does not exist", "domain.zig", A_POP, A_POP.replace(".published", ".publishd")),
 ("B method", "3 enum value that does not exist", "domain.zig", B_POP, B_POP.replace(".published", ".publishd")),
 ("C string", "3 enum value that does not exist (NOT CAUGHT: enum is text in this prototype)", "domain.zig", C_POP, C_POP.replace("published", "publishd")),

 ("A prefix", "4 attribute compared with an attribute of another type", "domain.zig", A_POP, A_POP.replace(".arg(.min_views)", ".attr(.title)")),
 ("B method", "4 attribute compared with an attribute of another type", "domain.zig", B_POP, B_POP.replace(".arg(.min_views)", ".attr(.title)")),
 ("C string", "4 attribute compared with an attribute of another type", "domain.zig", C_POP, C_POP.replace("$min_views", "title")),

 ("A prefix", "5 argument that does not exist", "domain.zig", A_POP, A_POP.replace(".arg(.min_views)", ".arg(.min_view)")),
 ("C string", "5 argument that does not exist", "domain.zig", C_POP, C_POP.replace("$min_views", "$min_view")),

 ("A prefix", "6 argument of the wrong type", "domain.zig", A_POP, A_POP.replace(".gt(.views, .arg(.min_views))", ".eq(.title, .arg(.min_views))")),

 ("A prefix", "7 calculation that does not exist", "domain.zig", ".cmp(i64, .gt, .calc(.popularity), .value(100)),", ".cmp(i64, .gt, .calc(.popularty), .value(100)),"),
 ("A prefix", "8 calculation used at the wrong type", "domain.zig", ".cmp(i64, .gt, .calc(.popularity), .value(100)),", '.cmp([]const u8, .gt, .calc(.popularity), .value("x")),'),

 ("A prefix", "9 missing attribute on the far side of a relationship", "domain.zig", ".exists(Comment, .comments, .eq(.flagged, .value(true)))),", ".exists(Comment, .comments, .eq(.flaged, .value(true)))),"),
 ("C string", "9 missing attribute on the far side of a relationship", "domain.zig", "exists(comments, flagged == true) and author.name", "exists(comments, flaged == true) and author.name"),
 ("A prefix", "10 relationship that does not exist", "domain.zig", ".exists(Comment, .comments, .eq(.flagged, .value(true)))),", ".exists(Comment, .coments, .eq(.flagged, .value(true)))),"),
 ("A prefix", "11 wrong destination named for a relationship (NOT CAUGHT unless an attribute name differs)", "domain.zig", ".related(Author, .author, .attr(.name))", ".related(Comment, .author, .attr(.flagged))"),

 ("A prefix", "12 non-boolean term in a boolean join", "domain.zig", A_POP, A_POP.replace(".gt(.views, .arg(.min_views)),", ".attr(.views),")),
 ("C string", "12 non-boolean term in a boolean join", "domain.zig", C_POP, C_POP.replace("views > $min_views", "views")),
 ("C string", "13 syntax error", "domain.zig", C_POP, C_POP.replace("views > $min_views", "(views > $min_views")),

 ("A prefix", "14 atomic update: value of the wrong type", "domain.zig", ".to(.views, .add(.attr(.views), .value(1)))", ".to(.views, .attr(.title))"),
 ("A prefix", "15 calculation body of the wrong type", "domain.zig", '.calc("popularity", i64, .add(.attr(.views), .attr(.likes)))', '.calc("popularity", i64, .add(.attr(.views), .attr(.title)))'),

 ("A prefix", "16 call site: missing attribute", "main.zig", ".gt(.likes, .value(min_likes))", ".gt(.liks, .value(min_likes))"),
 ("A prefix", "17 call site: runtime value of the wrong type", "main.zig", ".eq(.featured, .value(true))", ".eq(.featured, .value(min_likes))"),
]
out = []
for who, title, f, old, new in M:
    d = tempfile.mkdtemp()
    for n in os.listdir(here):
        if n.endswith(".zig") or n == "mise.toml": shutil.copy(os.path.join(here, n), d)
    p = os.path.join(d, f); s = open(p).read(); assert old in s, title
    open(p, "w").write(s.replace(old, new, 1))
    r = subprocess.run(["zig", "build-exe", "main.zig", "-fno-emit-bin"], cwd=d, capture_output=True, text=True).stderr
    lines = r.splitlines()
    keep = []
    for i, l in enumerate(lines):
        if re.search(r": (error|note): ", l) and "lib/std" not in l:
            keep += [l.replace(d + "/", "")] + [x for x in lines[i+1:i+3] if not re.search(r": (error|note): ", x)]
        if l.startswith("referenced by") or len(keep) > 14: break
    if not keep: keep = ["(compiled without error)"]
    out.append(f"=== [{who}] {title}\n    {f}: `{old}` -> `{new}`\n" + "\n".join(keep) + "\n")
    shutil.rmtree(d)
open(os.path.join(here, "errors.txt"), "w").write("\n".join(out))
print("\n".join(out))
