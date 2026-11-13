#!/usr/bin/env python3
"""PROTOTYPE. One mistake at a time in each probe; records where the compiler points."""
import os, re, shutil, subprocess, tempfile
here = os.path.dirname(os.path.abspath(__file__))
FILTER_REL = ".exists(.comments, .attr(.flagged)),\n        ),"
FILTER_CALC = ".gt(i64, .calc(.popularity), .value(100)),\n            .exists"
M = [
 ("probe_split.zig", "1 a calculation reads a calculation", "// CALC-TO-CALC ", ""),
 ("probe_split.zig", "2 relationship that does not exist", FILTER_REL, FILTER_REL.replace(".comments", ".coments")),
 ("probe_split.zig", "3 calculation that does not exist", FILTER_CALC, FILTER_CALC.replace(".popularity", ".popularty")),
 ("probe_split.zig", "4 calculation used at the wrong type", FILTER_CALC, FILTER_CALC.replace("i64, .calc(.popularity), .value(100)", "bool, .calc(.popularity), .value(true)")),
 ("probe_split.zig", "5 attribute that does not exist on the far side", FILTER_REL, FILTER_REL.replace(".flagged", ".flaged")),
 ("probe_types.zig", "1 a calculation reads a calculation", "", ""),
 ("probe_types.zig", "2 relationship that does not exist", FILTER_REL, FILTER_REL.replace(".comments", ".coments")),
 ("probe_types.zig", "3 calculation that does not exist", FILTER_CALC, FILTER_CALC.replace(".popularity", ".popularty")),
 ("probe_types.zig", "4 calculation used at the wrong type", FILTER_CALC, FILTER_CALC.replace("i64, .calc(.popularity), .value(100)", "bool, .calc(.popularity), .value(true)")),
 ("probe_types.zig", "5 attribute that does not exist on the far side", FILTER_REL, FILTER_REL.replace(".flagged", ".flaged")),
 ("probe_types.zig", "6 calculation declared, body missing", "            .hot = .gt(i64, .calc(.popularity), .value(100)),\n", ""),
 ("probe_types.zig", "7 body for a calculation that is not declared", ".hot = .gt(", ".hott = .gt("),
 ("probe_types.zig", "8 body of the wrong type", ".hot = .gt(i64, .calc(.popularity), .value(100)),", ".hot = .calc(.popularity),"),
]
out = []
for f, title, old, new in M:
    d = tempfile.mkdtemp()
    shutil.copy(os.path.join(here, f), d); shutil.copy(os.path.join(here, "mise.toml"), d)
    subprocess.run(["mise", "trust", d], capture_output=True)
    p = os.path.join(d, f); s = open(p).read(); assert old in s, title
    open(p, "w").write(s.replace(old, new, 1))
    r = subprocess.run(["zig", "build-exe", f, "-fno-emit-bin"], cwd=d, capture_output=True, text=True).stderr
    lines = r.splitlines(); keep = []
    for i, l in enumerate(lines):
        if re.search(r": (error|note): ", l) and "lib/std" not in l:
            keep += [l.replace(d + "/", "")] + [x for x in lines[i+1:i+3] if not re.search(r": (error|note): ", x)]
        if l.startswith("referenced by") or len(keep) > 11: break
    if not keep: keep = ["(compiled without error)"]
    out.append(f"=== [{f}] {title}\n    `{old}` -> `{new}`\n" + "\n".join(keep) + "\n")
    shutil.rmtree(d)
open(os.path.join(here, "probe_errors.txt"), "w").write("\n".join(out))
print("\n".join(out))
