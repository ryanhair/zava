#!/usr/bin/env python3
"""Follow-up to spelling c: where does an alias of the extension's named type complete?

Usage: python3 alias_probe.py <this dir> <zls> <zig> <scratch dir>   (prints to stdout)

Uses variants/domain_c_alias.zig plus a few extra declarations appended in the scratch copy.
"""
import os
import sys
import types

sys.path.insert(0, sys.argv[1])
import lsp_driver as L

args = types.SimpleNamespace(zls=sys.argv[2], zig=sys.argv[3], src=os.path.realpath(sys.argv[1]), scratch=os.path.realpath(sys.argv[4]))
os.makedirs(args.scratch, exist_ok=True)
ws = L.prepare(args, "alias-probe", "c_alias", True)
p = os.path.join(ws, "domain.zig")
EXTRA = '''const FilePg = postgres.Options(Author);
const AO = postgres.AttributeOptions;
const x1 = FilePg{ .table = "a" };
const x2 = AO{ .column = "c" };
const Plain = struct { a: u8 = 0, b: u8 = 0 };
const x3 = Plain{ .a = 1 };
fn f() void {
    const LP = postgres.Options(Author);
    const x4 = LP{ .table = "a" };
    _ = x4;
}

'''
t = open(p).read().replace("pub const resources =", EXTRA + "pub const resources =")
open(p, "w").write(t)
s = L.Session(args, ws, False)
text = s.open("domain.zig")
ctl = L.probes_for("c_alias")[0]
got, secs = L.wait_until(lambda: L.labels(L.region_probe(s, "domain.zig", text, *ctl[1:])[2]), 60)
print(f"control (top-level option names) answered after {secs}s: {got}")


def probe(what, old, new, anchor, kind=2):
    ed = text.replace(old, new)
    assert ed != text and text.count(old) == 1
    s.change("domain.zig", ed)
    pos = L.pos_of(ed, anchor)
    ctx = {"triggerKind": 2, "triggerCharacter": "."} if kind == 2 else {"triggerKind": 1}
    r = s.c.request(L.C, {"textDocument": {"uri": s.base + "domain.zig"}, "position": pos, "context": ctx})
    s.change("domain.zig", text)
    print(f"[{what}] {anchor!r} {'triggered by .' if kind == 2 else 'invoked'}\n    -> {L.digest(L.C, r, s.base)}")


POST = '.postgres = Pg{\n            .table = "posts",\n        }'
probe("file-scope alias of the generic call", 'FilePg{ .table = "a" }', "FilePg{ . }", "FilePg{ .§ }")
probe("file-scope alias of a plain struct", 'AO{ .column = "c" }', "AO{ . }", "AO{ .§ }")
probe("plain struct, no alias", "Plain{ .a = 1 }", "Plain{ . }", "Plain{ .§ }")
probe("function-local alias of the generic call", 'LP{ .table = "a" }', "LP{ . }", "LP{ .§ }")
probe("alias inside the resource struct; buffer does not parse", POST, ".postgres = Pg{ . }", ".postgres = Pg{ .§ }")
probe("alias inside the resource struct; buffer does not parse", POST, ".postgres = Pg{ . }", ".postgres = Pg{ .§ }", 1)
probe("alias inside the resource struct; buffer parses", POST, ".postgres = Pg{ .t }", ".postgres = Pg{ .t§ }", 1)
probe("alias inside the resource struct; buffer parses, no matching name", POST, ".postgres = Pg{ .x }", ".postgres = Pg{ .x§ }", 1)
probe("alias inside the resource struct, after an option; buffer does not parse", POST, '.postgres = Pg{ .table = "posts", . }', '"posts", .§ }')
probe("alias inside the resource struct, after an option; buffer does not parse", POST, '.postgres = Pg{ .table = "posts", .a }', '"posts", .a§ }', 1)
probe("alias inside the resource struct, through @as", POST, ".postgres = @as(Pg, .{ . })", "@as(Pg, .{ .§ })")
s.close()
