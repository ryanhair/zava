#!/usr/bin/env python3
"""Drive ZLS over LSP (JSON-RPC on stdio) and record the raw responses.

Usage:
    python3 lsp_driver.py --zls /path/to/zls --zig /path/to/zig \
        --src /path/to/this/dir --scratch /path/to/empty/scratch/dir --out results \
        [--only probes,diagnostics]

`--src` is the directory holding base/ and variants/. Every run copies base/ plus
one variants/domain_*.zig (as domain.zig) into a fresh directory under `--scratch`
(never run it inside the repository: build-on-save creates .zig-cache and the
diagnostics runs edit the files).

The client (Client, Session, pos_of, digest) is the one from
docs/research/zls-generated-source-and-declarations/lsp_driver.py on branch
research/zls-generated-source, unchanged. Cursor positions are found from anchor
strings containing the marker '§', never hard-coded. If a probe has an "edit"
(old, new) pair, `old` is replaced by `new` in the open document (full-text
didChange) before the request, and the original text is restored afterwards.

Outputs:
    <out>/raw.json      every request and full raw response
    <out>/summary.txt   a compact human-readable digest
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time

M = "§"


class Client:
    def __init__(self, zls, config, extra_args=()):
        self.proc = subprocess.Popen([zls, *extra_args], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.config = config
        self.next_id = 1
        self.responses = {}
        self.notifications = []
        self.cv = threading.Condition()
        self.t0 = time.time()
        threading.Thread(target=self._reader, daemon=True).start()

    def _send(self, msg):
        body = json.dumps(msg).encode()
        self.proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        self.proc.stdin.flush()

    def _reader(self):
        out = self.proc.stdout
        while True:
            length = None
            while True:
                line = out.readline()
                if not line:
                    return
                line = line.strip()
                if not line:
                    break
                if line.lower().startswith(b"content-length:"):
                    length = int(line.split(b":")[1])
            msg = json.loads(out.read(length))
            if "method" in msg and "id" in msg:  # server -> client request
                self._send({"jsonrpc": "2.0", "id": msg["id"], "result": self._answer(msg)})
                with self.cv:
                    self.notifications.append({"t": round(time.time() - self.t0, 2), "server_request": msg})
            elif "method" in msg:
                with self.cv:
                    self.notifications.append({"t": round(time.time() - self.t0, 2), **msg})
                    self.cv.notify_all()
            else:
                with self.cv:
                    self.responses[msg["id"]] = msg
                    self.cv.notify_all()

    def _answer(self, msg):
        if msg["method"] == "workspace/configuration":
            # ZLS 0.17.0 asks for a single item with section "zls" and expects one object back.
            return [self.config if item.get("section") == "zls" else None for item in msg["params"]["items"]]
        return None

    def request(self, method, params, timeout=60):
        rid = self.next_id
        self.next_id += 1
        self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        deadline = time.time() + timeout
        with self.cv:
            while rid not in self.responses:
                left = deadline - time.time()
                if left <= 0:
                    return {"error": "TIMEOUT (driver)"}
                self.cv.wait(left)
            r = self.responses.pop(rid)
        return r.get("result") if "error" not in r else {"error": r["error"]}

    def notify(self, method, params):
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    def diagnostics(self, uri):
        with self.cv:
            for n in reversed(self.notifications):
                if n.get("method") == "textDocument/publishDiagnostics" and n["params"]["uri"] == uri:
                    return n["params"]["diagnostics"]
        return None

    def logs(self):
        with self.cv:
            return [n for n in self.notifications if n.get("method") in ("window/logMessage", "window/showMessage")]

    def server_requests(self):
        with self.cv:
            return [n["server_request"] for n in self.notifications if "server_request" in n]

    def close(self):
        self.request("shutdown", None, timeout=10)
        self.notify("exit", None)
        try:
            self.proc.wait(5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


CAPS = {
    "general": {"positionEncodings": ["utf-16"]},
    "workspace": {
        "configuration": True,
        "workspaceFolders": True,
        "didChangeConfiguration": {"dynamicRegistration": True},
        "didChangeWatchedFiles": {"dynamicRegistration": True},
    },
    "window": {"workDoneProgress": True},
    "textDocument": {
        "synchronization": {"didSave": True},
        "publishDiagnostics": {"relatedInformation": True},
        "completion": {
            "completionItem": {
                "snippetSupport": True,
                "documentationFormat": ["markdown", "plaintext"],
                "labelDetailsSupport": True,
                "insertReplaceSupport": True,
            }
        },
        "hover": {"contentFormat": ["markdown", "plaintext"]},
        "signatureHelp": {"signatureInformation": {"documentationFormat": ["markdown"], "parameterInformation": {"labelOffsetSupport": True}}},
        "definition": {"linkSupport": True},
        "typeDefinition": {"linkSupport": True},
        "inlayHint": {},
    },
}

C, H, D, T, S = (
    "textDocument/completion",
    "textDocument/hover",
    "textDocument/definition",
    "textDocument/typeDefinition",
    "textDocument/signatureHelp",
)


def pos_of(text, anchor):
    plain = anchor.replace(M, "")
    idx = text.find(plain)
    if idx < 0:
        raise SystemExit(f"anchor not found: {anchor!r}")
    if text.find(plain, idx + 1) >= 0:
        raise SystemExit(f"anchor not unique: {anchor!r}")
    off = idx + anchor.index(M)
    line = text.count("\n", 0, off)
    col = off - (text.rfind("\n", 0, off) + 1)
    return {"line": line, "character": col}


def labels(result):
    if result is None or (isinstance(result, dict) and "error" in result):
        return []
    items = result["items"] if isinstance(result, dict) else result
    return [it["label"] for it in items]


def digest(method, result, uri_base):
    if result is None:
        return "null"
    if isinstance(result, dict) and "error" in result and len(result) == 1:
        return "ERROR " + json.dumps(result["error"])
    if method == C:
        items = result["items"] if isinstance(result, dict) else result
        parts = []
        for it in items[:30]:
            ld = it.get("labelDetails") or {}
            extra = it.get("detail") or ld.get("description") or ld.get("detail") or ""
            parts.append(f"{it['label']}" + (f" [{extra}]" if extra else ""))
        more = f" ... (+{len(items) - 30} more)" if len(items) > 30 else ""
        return f"{len(items)} items: " + "; ".join(parts) + more
    if method == H:
        c = result.get("contents")
        v = c.get("value") if isinstance(c, dict) else str(c)
        return json.dumps(v)
    if method in (D, T):
        locs = result if isinstance(result, list) else [result]
        out = []
        for l in locs:
            uri = l.get("targetUri") or l.get("uri")
            rng = l.get("targetSelectionRange") or l.get("range")
            out.append(f"{uri.replace(uri_base, '')}:{rng['start']['line'] + 1}:{rng['start']['character'] + 1}")
        return ", ".join(out) or "[]"
    if method == S:
        sigs = result.get("signatures", [])
        return f"activeParameter={result.get('activeParameter')} " + " | ".join(
            s["label"] + " params=" + json.dumps([p["label"] for p in s.get("parameters", [])])
            + (" doc=" + json.dumps((s.get("documentation") or {}).get("value", "")) if s.get("documentation") else "")
            for s in sigs
        )
    return json.dumps(result)


class Session:
    """One ZLS process attached to one workspace directory."""

    def __init__(self, args, ws, build_on_save):
        self.ws = os.path.realpath(ws)
        self.base = "file://" + self.ws + "/"
        cfg_path = os.path.join(os.path.dirname(self.ws), "empty-zls.json")
        if not os.path.exists(cfg_path):
            open(cfg_path, "w").write("{}\n")
        self.c = Client(args.zls, {"zig_exe_path": args.zig, "enable_build_on_save": build_on_save},
                        ["--config-path", cfg_path, "--log-level", "debug"])
        self.started = time.time()
        self.init = self.c.request("initialize", {
            "processId": os.getpid(), "rootUri": self.base.rstrip("/"), "capabilities": CAPS,
            "workspaceFolders": [{"uri": self.base.rstrip("/"), "name": "probe"}],
        })
        self.c.notify("initialized", {})
        self.docs = {}  # name -> (original text, version)

    def open(self, name):
        text = open(os.path.join(self.ws, name)).read()
        self.c.notify("textDocument/didOpen", {"textDocument": {"uri": self.base + name, "languageId": "zig", "version": 1, "text": text}})
        self.docs[name] = [text, 1]
        return text

    def change(self, name, text):
        self.docs[name][1] += 1
        self.c.notify("textDocument/didChange", {"textDocument": {"uri": self.base + name, "version": self.docs[name][1]}, "contentChanges": [{"text": text}]})

    def save_to_disk(self, name, text):
        """What an editor does on save: buffer change, write, didSave."""
        self.change(name, text)
        open(os.path.join(self.ws, name), "w").write(text)
        self.docs[name][0] = text
        self.c.notify("textDocument/didSave", {"textDocument": {"uri": self.base + name}})

    def probe(self, name, method, anchor, edit=None):
        original = self.docs[name][0]
        text = original
        if edit:
            old, new = edit
            assert original.count(old) == 1, f"edit target not unique in {name}: {old!r}"
            text = original.replace(old, new.replace(M, ""))
        self.change(name, text)
        pos = pos_of(text, anchor)
        params = {"textDocument": {"uri": self.base + name}, "position": pos}
        if method == C:
            params["context"] = {"triggerKind": 2, "triggerCharacter": "."} if anchor[anchor.index(M) - 1] == "." else {"triggerKind": 1}
        if method == S:
            params["context"] = {"triggerKind": 1, "isRetrigger": False}
        result = self.c.request(method, params)
        if edit:
            self.change(name, original)
        return pos, result

    def watched_events(self, snapshot):
        """Send didChangeWatchedFiles for every *.zig/*.zon under the workspace that is new or changed
        since `snapshot` (as an editor honouring ZLS's `**/*.{zig,zon}` registration would)."""
        now = snap(self.ws)
        changes = []
        for p, m in now.items():
            if p not in snapshot:
                changes.append({"uri": "file://" + p, "type": 1})
            elif snapshot[p] != m:
                changes.append({"uri": "file://" + p, "type": 2})
        for p in snapshot:
            if p not in now:
                changes.append({"uri": "file://" + p, "type": 3})
        if changes:
            self.c.notify("workspace/didChangeWatchedFiles", {"changes": changes})
        return now, changes

    def close(self):
        self.c.close()


def snap(ws):
    out = {}
    for root, dirs, files in os.walk(ws):
        for f in files:
            if f.endswith((".zig", ".zon")):
                p = os.path.join(root, f)
                try:
                    st = os.stat(p)
                    out[p] = (st.st_mtime_ns, st.st_size)
                except FileNotFoundError:
                    pass
    return out


# ---------------------------------------------------------------- the spellings

HELPER = (
    "\n/// ADDED for spelling d (not in the prototype): gives the anonymous literal a result type.\n"
    "pub fn entry(comptime R: type, o: Options(R)) Options(R) {\n    return o;\n}\n"
)

# name -> (text that opens the entry, text that opens a per-attribute entry, indentation of the entry body)
SPELLINGS = {
    "a_anon": (".postgres = .{", ".{", 12),
    "b_named": (".postgres = postgres.Options(@This()){", ".{", 12),
    "b2_named_nested": (".postgres = postgres.Options(@This()){", "postgres.AttributeOptions{", 12),
    "c_alias": (".postgres = Pg{", ".{", 12),
    "c2_file_alias": (".postgres = AuthorPg{", ".{", 12),
    "d_helper": (".postgres = postgres.entry(@This(), .{", ".{", 12),
    "e_const": ("const pg: Pg = .{", ".{", 8),
    "f_control": (".postgres = .{", ".{", 12),  # spelling a, plus the control probes
}


def probes_for(v):
    """Probes for one spelling. Each: (name, method, anchor, edit or None, region) with region 'author', 'post' or 'ping'."""
    opn, ao, ind = SPELLINGS[v]
    sp = " " * ind
    table = '.table = "authors",'
    attrs = f'.attributes = .{{ .email = {ao} .column = "email_address" }} }},'
    body = f"{table}\n{sp}{attrs}"
    P = []
    # control: the top-level named type (ADR 0001) completes its option names in this session
    P.append(("control_top_level_option_names", C, '.primary_key = .id, .§ };', ('.primary_key = .id };', '.primary_key = .id, . };'), "ping"))
    # 1. extension names
    P.append(("ext_names_empty_block", C, ".extensions = .{ .§ } };", ('.primary_key = .id };', '.primary_key = .id, .extensions = .{ . } };'), "ping"))
    P.append(("ext_names_before_existing_entry", C, ".extensions = .{ .§, .postgres", (".extensions = .{ .postgres", ".extensions = .{ ., .postgres"), "author"))
    P.append(("ext_names_prefix", C, ".extensions = .{ .po§ } };", ('.primary_key = .id };', '.primary_key = .id, .extensions = .{ .po } };'), "ping"))
    # 2 / 3. the extension's option names
    P.append(("opt_names_empty_entry", C, f"{opn}\n{sp}.§\n", (body, "."), "author"))
    P.append(("opt_names_after_table", C, f"{table}\n{sp}.§\n", (attrs, "."), "author"))
    P.append(("opt_names_prefix", C, f"{opn}\n{sp}.ta§\n", (body, ".ta"), "author"))
    P.append(("opt_names_one_line", C, "{ .§ }", ('\n' + sp + '.table = "posts",\n' + sp[4:] + "}", " . }"), "post"))
    # nested levels
    P.append(("attr_keys", C, ".attributes = .{ .§ },\n" + sp[4:], (attrs, ".attributes = .{ . },"), "author"))
    P.append(("attr_entry_option_names", C, f".attributes = .{{ .email = {ao} .§ }} }},", (attrs, f".attributes = .{{ .email = {ao} . }} }},"), "author"))
    # hover / go-to-definition on the finished declaration
    for kind, m in (("hover", H), ("def", D)):
        P.append((f"{kind}_extensions_option", m, ".exten§sions = .{", None, "author"))
        if v != "e_const":
            P.append((f"{kind}_extension_name", m, ".post§gres = ", None, "author"))
        P.append((f"{kind}_option_table", m, '.tab§le = "authors"', None, "author"))
        P.append((f"{kind}_option_attributes", m, f".attri§butes = .{{ .email = {ao} .column", None, "author"))
        P.append((f"{kind}_attr_key", m, f".em§ail = {ao} .column", None, "author"))
        P.append((f"{kind}_attr_entry_option", m, '.col§umn = "email_address"', None, "author"))
        if "Options(@This()){" in opn:
            P.append((f"{kind}_named_type_Options", m, ".postgres = postgres.Opt§ions(@This()){", None, "author"))
            P.append((f"{kind}_named_type_module", m, ".postgres = post§gres.Options(@This()){", None, "author"))
        if ao.startswith("postgres."):
            P.append((f"{kind}_named_type_AttributeOptions", m, "postgres.Attribute§Options{ .column", None, "author"))
        if v == "c_alias":
            P.append((f"{kind}_alias_use", m, ".postgres = P§g{", None, "author"))
        if v == "c2_file_alias":
            P.append((f"{kind}_alias_use", m, ".postgres = Author§Pg{", None, "author"))
        if v == "d_helper":
            P.append((f"{kind}_helper_call", m, ".postgres = postgres.ent§ry(@This(), .{", None, "author"))
        if v == "e_const":
            P.append((f"{kind}_const_decl", m, "const p§g: Pg = .{", None, "author"))
            P.append((f"{kind}_const_use", m, ".extensions = .{ .postgres = p§g },", None, "author"))
            P.append((f"{kind}_extension_name", m, ".post§gres = pg", None, "author"))
    if v == "d_helper":
        P.append(("sig_helper_call", S, ".postgres = postgres.entry(§@This(), .{", None, "author"))
    if v == "f_control":
        whole = '.extensions = .{ .postgres = .{ .table = "authors", .attributes = .{ .email = .{ .column = "email_address" } } } } };'
        P.append(("control_ext_names", C, "Hand{ .extensions = .{ .§ } };", (whole, ".extensions = .{ . } };"), "control"))
        P.append(("control_opt_names", C, ".postgres = .{ .§ } } };", (whole, ".extensions = .{ .postgres = .{ . } } };"), "control"))
        P.append(("control_attr_keys", C, ".attributes = .{ .§ } } } };", (whole, '.extensions = .{ .postgres = .{ .table = "authors", .attributes = .{ . } } } };'), "control"))
        for kind, m in (("hover", H), ("def", D)):
            P.append((f"control_{kind}_extension_name", m, ".extensions = .{ .post§gres = .{", None, "control"))
            P.append((f"control_{kind}_option_table", m, '.tab§le = "authors"', None, "control"))
            P.append((f"control_{kind}_attr_entry_option", m, '.col§umn = "email_address"', None, "control"))
    return P


def regions(text):
    a = text.index("pub const Author = struct")
    p = text.index("pub const Post = struct")
    g = text.index("pub const Ping = struct")
    e = text.index("pub const resources")
    c = text.index("// CONTROL") if "// CONTROL" in text else e
    return {"author": (a, p), "post": (p, g), "ping": (g, c), "control": (c, e)}


def prepare(args, name, variant, check):
    ws = os.path.join(args.scratch, name)
    shutil.rmtree(ws, ignore_errors=True)
    shutil.copytree(os.path.join(args.src, "base"), ws)
    shutil.copy(os.path.join(args.src, "variants", f"domain_{variant}.zig"), os.path.join(ws, "domain.zig"))
    if variant == "d_helper":
        with open(os.path.join(ws, "postgres.zig"), "a") as f:
            f.write(HELPER)
    bz = os.path.join(ws, "build.zig")
    text = open(bz).read()
    text2 = re.sub(r"^const with_check = \w+;", f"const with_check = {'true' if check else 'false'};", text, flags=re.M)
    assert check or text2 != text
    open(bz, "w").write(text2)
    return os.path.realpath(ws)


def wait_until(fn, timeout, step=0.25):
    t0 = time.time()
    while True:
        v = fn()
        if v:
            return v, round(time.time() - t0, 2)
        if time.time() - t0 > timeout:
            return None, round(time.time() - t0, 2)
        time.sleep(step)


def bad_logs(s):
    return [n["params"]["message"] for n in s.c.logs() if n["params"].get("type") in (1, 2)]


def region_probe(s, fname, text, method, anchor, edit, region):
    lo, hi = regions(text)[region]
    part = text[lo:hi]
    if edit:
        assert part.count(edit[0]) == 1, f"edit target not unique in {region}: {edit[0]!r}"
        part = part.replace(edit[0], edit[1])
    edited = text[:lo] + part + text[hi:]
    s.change(fname, edited)
    rel = pos_of(part, anchor)
    off = lo + len("\n".join(part.split("\n")[: rel["line"]])) + (1 if rel["line"] else 0) + rel["character"]
    pos = {"line": edited.count("\n", 0, off), "character": off - (edited.rfind("\n", 0, off) + 1)}
    params = {"textDocument": {"uri": s.base + fname}, "position": pos}
    if method == C:
        ch = anchor[anchor.index(M) - 1]
        params["context"] = {"triggerKind": 2, "triggerCharacter": ch} if ch == "." else {"triggerKind": 1}
    if method == S:
        params["context"] = {"triggerKind": 1, "isRetrigger": False}
    result = s.c.request(method, params)
    s.change(fname, text)
    line = edited.split("\n")[pos["line"]]
    return pos, line[: pos["character"]] + M + line[pos["character"]:], result


def run_probes(args, raw, summary):
    """Measurements 1 to 3: completion, hover and go-to-definition in each spelling. Build-on-save off."""
    for v in SPELLINGS:
        ws = prepare(args, "probe-" + v, v, True)
        build = subprocess.run([args.zig, "build", "run"], cwd=ws, capture_output=True, text=True)
        subprocess.run([args.zig, "build"], cwd=ws, capture_output=True, text=True)
        api = open(os.path.join(ws, "zig-out", "api.zig"), "rb").read() if build.returncode == 0 else b""
        summary.append(f"===== probes[{v}] =====")
        summary.append(f"`zig build run` exit {build.returncode}; generated api.zig sha256 {hashlib.sha256(api).hexdigest()[:16]}")
        s = Session(args, ws, False)
        raw.setdefault("server_info", s.init.get("serverInfo"))
        text = s.open("domain.zig")
        summary.append("variant: " + " ".join(l[4:] for l in text.split("\n")[:6] if l.startswith("//! ")))
        plist = probes_for(v)
        ctl = plist[0]
        got, secs = wait_until(lambda: labels(region_probe(s, "domain.zig", text, *ctl[1:])[2]), args.resolve_wait)
        summary.append(f"time from didOpen(domain.zig) until the control completion answers: {str(secs) + 's' if got else 'NEVER within ' + str(secs) + 's'}")
        rec = raw["probes"][v] = {"build_exit": build.returncode, "api_sha256": hashlib.sha256(api).hexdigest(), "probes": {}}
        for pname, method, anchor, edit, region in plist:
            pos, shown, result = region_probe(s, "domain.zig", text, method, anchor, edit, region)
            rec["probes"][pname] = {"method": method, "region": region, "line_with_cursor": shown, "edited": bool(edit), "position": pos, "result": result}
            summary.append(f"[{pname}] {method.split('/')[1]} in {region} @ {shown.strip()!r}\n    -> {digest(method, result, s.base)}")
        rec["log"] = s.c.logs()
        summary.append("ZLS warnings/errors: " + (json.dumps(bad_logs(s)) if bad_logs(s) else "none"))
        s.close()
        summary.append("")
        print("\n".join(summary[-4:]), file=sys.stderr)


# ---------------------------------------------------------------- measurement 4: diagnostics

MISSPELLINGS = [
    # name, old, new, the misspelt identifier (first occurrence in the Author region is the expected location)
    ("extension_name", ".postgres = ", ".postgers = ", "postgers"),
    ("option_name", '.table = "authors"', '.tabel = "authors"', "tabel"),
    ("attribute_key", ".email = .{ .column", ".emial = .{ .column", "emial"),
    ("attribute_option", '.column = "email_address"', '.colum = "email_address"', "colum"),
]

DIAG_CONFIGS = [
    # name, check step in build.zig, enable_build_on_save, which spellings, which misspellings (None = all)
    ("check_step_bos_default", True, None, ("a_anon", "b_named"), None),
    ("no_check_step_bos_default", False, None, ("a_anon",), ("option_name",)),  # the prototype's build.zig as it stands
    ("no_check_step_bos_true", False, True, ("a_anon", "b_named"), ("extension_name", "option_name")),
]


def misspell(good, old, new, ident):
    lo, hi = regions(good)["author"]
    part = good[lo:hi]
    assert part.count(old) == 1, old
    bad = good[:lo] + part.replace(old, new) + good[hi:]
    off = bad.index(ident)
    line = bad.count("\n", 0, off)
    col = off - (bad.rfind("\n", 0, off) + 1)
    return bad, line + 1, col + 1  # 1-based position of the identifier (the '.' is one column to the left)


def compiler_errors(args, ws):
    """Plain `zig build` (the install step) in `ws`; returns the 'file:line:col: error|note: ...' lines."""
    r = subprocess.run([args.zig, "build"], cwd=ws, capture_output=True, text=True)
    out = r.stderr.replace(ws + "/", "")
    lines = [l for l in out.split("\n") if re.match(r"^\S+:\d+:\d+: (error|note): ", l)]
    return r.returncode, lines, out


def run_diagnostics(args, raw, summary):
    for cname, check, bos, spellings, which in DIAG_CONFIGS:
        for v in spellings:
            for mname, old, new, ident in MISSPELLINGS:
                if which and mname not in which:
                    continue
                key = f"{cname}/{v}/{mname}"
                summary.append(f"===== diagnostics[{key}] check_step={check} enable_build_on_save={bos} =====")
                ws = prepare(args, "diag", v, check)
                good = open(os.path.join(ws, "domain.zig")).read()
                bad, eline, ecol = misspell(good, old, new, ident)
                summary.append(f"misspelling: {old!r} -> {new!r}; identifier '{ident}' is at {eline}:{ecol} (its '.' at {eline}:{ecol - 1})")
                # the compiler by itself, in a separate copy
                ws2 = prepare(args, "diag-zigbuild", v, check)
                open(os.path.join(ws2, "domain.zig"), "w").write(bad)
                code, lines, out = compiler_errors(args, ws2)
                summary.append(f"`zig build`: exit {code}")
                summary.extend("    " + l for l in lines)
                rec = raw["diagnostics"][key] = {"expected_identifier_position": [eline, ecol], "zig_build_exit": code, "zig_build_error_lines": lines, "zig_build_stderr": out}
                # the editor
                s = Session(args, ws, bos)
                s.open("domain.zig")
                time.sleep(args.settle)
                before = s.c.diagnostics(s.base + "domain.zig")
                summary.append(f"before the edit, {args.settle}s after didOpen: diagnostics for domain.zig = {'never published' if before is None else json.dumps(before)}")
                mark = len(s.c.notifications)
                t0 = time.time()
                s.save_to_disk("domain.zig", bad)

                def published():
                    with s.c.cv:
                        for n in s.c.notifications[mark:]:
                            if n.get("method") == "textDocument/publishDiagnostics" and n["params"]["diagnostics"]:
                                return True
                    return False

                got, _ = wait_until(published, args.diag_wait)
                secs = round(time.time() - t0, 2)
                time.sleep(1.5)
                pubs = {}
                with s.c.cv:
                    for n in s.c.notifications[mark:]:
                        if n.get("method") == "textDocument/publishDiagnostics":
                            pubs[n["params"]["uri"].replace(s.base, "")] = n["params"]["diagnostics"]
                rec["published_after_save"] = pubs
                rec["seconds_until_first_diagnostic"] = secs if got else None
                if not got:
                    summary.append(f"after saving the misspelling: NO diagnostics within {secs}s")
                else:
                    summary.append(f"after saving the misspelling: first non-empty publishDiagnostics after {secs}s")
                    for f, ds in pubs.items():
                        for d in ds:
                            st, en = d["range"]["start"], d["range"]["end"]
                            where = f"{st['line'] + 1}:{st['character'] + 1}-{en['line'] + 1}:{en['character'] + 1}"
                            hit = "ON the misspelt identifier" if (f == "domain.zig" and st["line"] + 1 == eline and st["character"] + 1 in (ecol, ecol - 1)) else "elsewhere"
                            summary.append(f"    {f} {where} severity={d.get('severity')} source={d.get('source')!r} [{hit}] {d['message']!r}")
                            for ri in d.get("relatedInformation") or []:
                                r0 = ri["location"]["range"]["start"]
                                summary.append(f"        related: {ri['location']['uri'].replace(s.base, '')}:{r0['line'] + 1}:{r0['character'] + 1} {ri['message']!r}")
                # fix it and save: do the diagnostics clear?
                if got:
                    mark2 = len(s.c.notifications)
                    t1 = time.time()
                    s.save_to_disk("domain.zig", good)

                    def cleared():
                        with s.c.cv:
                            ns = [n for n in s.c.notifications[mark2:] if n.get("method") == "textDocument/publishDiagnostics" and n["params"]["uri"] == s.base + "domain.zig"]
                        return bool(ns) and not ns[-1]["params"]["diagnostics"]

                    ok, _ = wait_until(cleared, args.diag_wait)
                    first_clear = round(time.time() - t1, 2)
                    time.sleep(args.after_fix)  # a rebuild may still be running: report the state it settles in
                    with s.c.cv:
                        line = [(n["t"], len(n["params"]["diagnostics"])) for n in s.c.notifications[mark:]
                                if n.get("method") == "textDocument/publishDiagnostics" and n["params"]["uri"] == s.base + "domain.zig"]
                    final = s.c.diagnostics(s.base + "domain.zig")
                    t_bad, t_good = round(t0 - s.c.t0, 2), round(t1 - s.c.t0, 2)
                    rec["seconds_until_cleared"] = first_clear if ok else None
                    rec["publish_timeline"] = {"saved_bad_at": t_bad, "saved_good_at": t_good, "publishes": line}
                    rec["final_diagnostics"] = final
                    summary.append(f"after fixing and saving: diagnostics for domain.zig {'first empty after ' + str(first_clear) + 's' if ok else 'NOT cleared within ' + str(args.diag_wait) + 's'}; "
                                   f"{args.after_fix}s later: {len(final or [])} diagnostics")
                    summary.append(f"    publishDiagnostics(domain.zig) timeline, seconds since ZLS start: misspelling saved at {t_bad}, fix saved at {t_good}; "
                                   + ", ".join(f"{t}:{k}" for t, k in line))
                rec["log"] = s.c.logs()
                info = [n["params"]["message"] for n in s.c.logs() if "uild" in n["params"]["message"] and "save" in n["params"]["message"].lower()]
                summary.append("ZLS log lines mentioning build on save: " + json.dumps(info[:6]))
                summary.append("ZLS warnings/errors: " + (json.dumps(bad_logs(s)) if bad_logs(s) else "none"))
                s.close()
                summary.append("")
                print("\n".join(summary[-12:]), file=sys.stderr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zls", required=True)
    ap.add_argument("--zig", required=True)
    ap.add_argument("--src", required=True)
    ap.add_argument("--scratch", required=True)
    ap.add_argument("--out", default="results")
    ap.add_argument("--only", default="probes,diagnostics")
    ap.add_argument("--resolve-wait", type=float, default=60.0)
    ap.add_argument("--settle", type=float, default=12.0, help="seconds between didOpen and the misspelling being saved")
    ap.add_argument("--diag-wait", type=float, default=30.0)
    ap.add_argument("--after-fix", type=float, default=6.0, help="seconds to keep listening after the fix is saved")
    args = ap.parse_args()
    args.src = os.path.realpath(args.src)
    os.makedirs(args.scratch, exist_ok=True)
    args.scratch = os.path.realpath(args.scratch)
    os.makedirs(args.out, exist_ok=True)
    only = set(args.only.split(","))

    raw = {"zls_version": subprocess.check_output([args.zls, "--version"]).decode().strip(),
           "zig_version": subprocess.check_output([args.zig, "version"]).decode().strip(),
           "probes": {}, "diagnostics": {}}
    summary = [f"ZLS {raw['zls_version']}  Zig {raw['zig_version']}", ""]
    if "probes" in only:
        run_probes(args, raw, summary)
    if "diagnostics" in only:
        run_diagnostics(args, raw, summary)

    def scrub(text):
        return text.replace(args.scratch, "/SCRATCH").replace(os.path.expanduser("~"), "~")

    tag = "" if only >= {"probes", "diagnostics"} else "-partial"
    open(os.path.join(args.out, f"raw{tag}.json"), "w").write(scrub(json.dumps(raw, indent=1)))
    open(os.path.join(args.out, f"summary{tag}.txt"), "w").write(scrub("\n".join(summary) + "\n"))


if __name__ == "__main__":
    sys.exit(main())
