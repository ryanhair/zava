#!/usr/bin/env python3
"""PROTOTYPE. Makes one mistake at a time in a copy of the prototype and records where the compiler points."""
import os, re, shutil, subprocess, tempfile
here = os.path.dirname(os.path.abspath(__file__))
A_POP = '.eq(.status, .value(.published)),\n                    .gt(.views, .arg(.min_views)),'
B_POP = 'p.attr(.status).eq(.value(.published)).andAlso(p.attr(.views).gt(.arg(.min_views)))'
C_POP = '"status == \'published\' and views > $min_views"'
M = [
 ('destination named', '1 missing attribute on the far side', 'domain.zig', '.not(.exists(Comment, .comments, .eq(.flagged, .value(true)))),', '.not(.exists(Comment, .comments, .eq(.flaged, .value(true)))),'),
 ('destination not named', '1 missing attribute on the far side', 'domain.zig', '.not(.existsLoose(.comments, .eq(.flagged, .value(true)))),', '.not(.existsLoose(.comments, .eq(.flaged, .value(true)))),'),
 ('destination named', '2 literal of the wrong type on the far side', 'domain.zig', '.not(.exists(Comment, .comments, .eq(.flagged, .value(true)))),', '.not(.exists(Comment, .comments, .eq(.flagged, .value("yes")))),'),
 ('destination not named', '2 literal of the wrong type on the far side', 'domain.zig', '.not(.existsLoose(.comments, .eq(.flagged, .value(true)))),', '.not(.existsLoose(.comments, .eq(.flagged, .value("yes")))),'),
 ('destination named', '3 relationship that does not exist', 'domain.zig', '.not(.exists(Comment, .comments, .eq(.flagged, .value(true)))),', '.not(.exists(Comment, .coments, .eq(.flagged, .value(true)))),'),
 ('destination not named', '3 relationship that does not exist', 'domain.zig', '.not(.existsLoose(.comments, .eq(.flagged, .value(true)))),', '.not(.existsLoose(.coments, .eq(.flagged, .value(true)))),'),
 ('destination named', '4 far attribute of the wrong type for the comparison', 'domain.zig', '.related(Author, .author, .attr(.name))', '.related(Author, .author, .attr(.id))'),
 ('destination not named', '4 far attribute of the wrong type for the comparison', 'domain.zig', '.relatedLoose(.author, .attr(.name))', '.relatedLoose(.author, .attr(.id))'),
 ('destination named', '5 wrong destination named, attribute exists on both with the same type (id)', 'domain.zig', '.cmp(i64, .gt, .calc(.popularity), .value(100)),', '.cmp(i64, .gt, .related(Comment, .author, .attr(.id)), .value(100)),'),
 ('destination named', '6 wrong destination named, attribute only on the wrong one', 'domain.zig', '.not(.exists(Comment, .comments, .eq(.flagged, .value(true)))),', '.not(.exists(Author, .comments, .eq(.name, .value("x")))),'),
 ('destination named', '7 to-one relationship given to exists', 'domain.zig', '.not(.exists(Comment, .comments, .eq(.flagged, .value(true)))),', '.not(.exists(Author, .author, .eq(.name, .value("x")))),'),
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
open(os.path.join(here, "errors_relationship.txt"), "w").write("\n".join(out))
print("\n".join(out))
