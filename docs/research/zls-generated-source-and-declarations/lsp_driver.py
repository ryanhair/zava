#!/usr/bin/env python3
"""Drive ZLS over LSP (JSON-RPC on stdio) and record the raw responses.

Usage:
    python3 lsp_driver.py --zls /path/to/zls --zig /path/to/zig \
        --src /path/to/this/dir --scratch /path/to/empty/scratch/dir --out results \
        [--only features,broken,fresh,q2] [--configs name,name]

`--src` is the directory holding q1/ and q2/. Every run copies its inputs into a
fresh directory under `--scratch` (never run it inside the repository:
build-on-save creates .zig-cache and the freshness runs edit the files).

Cursor positions are found from anchor strings containing the marker '§',
never hard-coded. If a probe has an "edit" (old, new) pair, `old` is replaced
by `new` in the open document (full-text didChange) before the request.

The client plays the part of an editor:
  * it answers `workspace/configuration` with one object per requested item
    (ZLS asks for a single item with section "zls");
  * it accepts dynamic registration of `workspace/didChangeWatchedFiles` and,
    when a run says so, sends the events an editor's file watcher would send.

Outputs:
    <out>/raw.json      every request and full raw response
    <out>/summary.txt   a compact human-readable digest
"""
import argparse
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


def generated_files(ws):
    """Every api.zig the build has produced, with whether it already has the freshness edit."""
    out = {}
    for p in snap(ws):
        if os.path.basename(p) == "api.zig":
            out[p.replace(ws, "")] = "FRESH" if FRESH_MARK in open(p).read() else "old"
    return out


# ---------------------------------------------------------------- question 1 and 3: probes

APP = [
    ("api_members", C, "const blank2 = api.§;", ("    var in:", "    const blank2 = api.;\n    var in:")),
    ("api_Author_members", C, "const blank2 = api.Author.§;", ("    var in:", "    const blank2 = api.Author.;\n    var in:")),
    ("api_Post_members", C, "const blank2 = api.Post.§;", ("    var in:", "    const blank2 = api.Post.;\n    var in:")),
    ("input_literal_register", C, "api.Author.register(blank, .{ .§ });",
     ('api.Author.register(blank, .{ .email = "a@b.c", .name = "ann" });', "api.Author.register(blank, .{ .§ });")),
    ("input_literal_rename", C, "api.Author.rename(a, .{ .§ });",
     ('api.Author.rename(a, .{ .name = "bob" });', "api.Author.rename(a, .{ .§ });")),
    ("input_literal_draft", C, "api.Post.draft(empty, .{ .§ });",
     ('api.Post.draft(empty, .{ .author_id = 2, .title = "t", .body = null });', "api.Post.draft(empty, .{ .§ });")),
    ("input_literal_typed_decl", C, "var in: api.Author.RegisterInput = .{ .§ };",
     ('var in: api.Author.RegisterInput = .{ .email = "x", .name = "y" };', "var in: api.Author.RegisterInput = .{ .§ };")),
    ("record_literal_fields", C, "const blank: api.Author.Record = .{ .§ };",
     ('const blank: api.Author.Record = .{ .id = 1, .email = "", .name = "" };', "const blank: api.Author.Record = .{ .§ };")),
    ("fields_on_input_var", C, "in.§;", ('in.name = "z";', "in.§;")),
    ("fields_on_result", C, "const b = a.§;", ('const b = api.Author.rename(a, .{ .name = "bob" });', "const b = a.§;")),
    ("fields_on_post_result", C, "const q = p.§;", ("const q = api.Post.publish(p, .{ .published = true });", "const q = p.§;")),
    ("hover_fn_register", H, "api.Author.regi§ster(blank", None),
    ("hover_fn_rename", H, "api.Author.ren§ame(a", None),
    ("hover_fn_draft", H, "api.Post.dr§aft(empty", None),
    ("hover_input_type", H, "var in: api.Author.Register§Input", None),
    ("hover_input_var", H, "var i§n: api.Author.RegisterInput", None),
    ("hover_result", H, "const §a = api.Author.register", None),
    ("hover_post_result", H, "const §p = api.Post.draft", None),
    ("hover_api_import", H, "const a§pi = @import", None),
    ("hover_literal_field", H, '.{ .em§ail = "a@b.c"', None),
    ("sig_register", S, "api.Author.register(blank, §.{ .email", None),
    ("sig_draft", S, "api.Post.draft(§empty", None),
    ("def_fn_register", D, "api.Author.regi§ster(blank", None),
    ("def_fn_draft", D, "api.Post.dr§aft(empty", None),
    ("def_input_type", D, "var in: api.Author.Register§Input", None),
    ("def_literal_field", D, '.{ .em§ail = "a@b.c"', None),
    ("def_api_identifier", D, "const a = a§pi.Author", None),
    ("def_import_string", D, '@import("a§pi")', None),
    ("def_field_on_result", D, "a.em§ail, b.name", None),
    ("typedef_input_var", T, "i§n.name = ", None),
]

DOMAIN = [
    ("api_members", C, "_ = api.§;", ("_ = input.email;", "_ = api.;")),
    ("api_Author_members", C, "_ = api.Author.§;", ("_ = input.email;", "_ = api.Author.;")),
    ("hover_hook_param", H, "pub fn welcome(self: *Author, in§put:", None),
    ("hover_hook_param_type", H, "input: api.Author.Register§Input) void", None),
    ("fields_on_hook_param", C, "_ = input.§;\n    }\n};\n\npub const Post", ("_ = input.email;", "_ = input.;")),
    ("post_fields_on_hook_param", C, "_ = input.§;\n    }\n};\n\npub const resources", ("_ = input.title;", "_ = input.;")),
    ("def_hook_param_type", D, "input: api.Author.Register§Input) void", None),
    ("def_import_string", D, '@import("a§pi")', None),
    ("literal_in_hook_body", C, "api.Author.rename(self.*, .{ .§ });",
     ('api.Author.rename(self.*, .{ .name = "Welcome" });', "api.Author.rename(self.*, .{ .§ });")),
    ("sig_in_hook_body", S, "api.Author.rename(§self.*", None),
    # what the declaration itself offers in this (prototype) shape
    ("decl_accept_member", C, '.{ .name = "rename", .accept = &.{.§} },', ('.accept = &.{.name} },', ".accept = &.{.} },")),
    ("decl_after_member", C, ".after = .§ },\n        .{ .name = \"rename\"", (".after = .welcome },", ".after = . },")),
    ("decl_action_option", C, '.{ .name = "rename", .§ },', ('.{ .name = "rename", .accept = &.{.name} },', '.{ .name = "rename", . },')),
]

ZAVA = [
    # generic comptime code, parameter typed Generated(R, name)
    ("generic_hover_input_param", H, "base: R, in§put: Generated(R, inputShape(R, action).name)) R {", None),
    ("generic_fields_on_input", C, "    _ = input.§;\n    return r;\n}\n\n/// Comparison", ("    return r;\n}\n\n/// Comparison", "    _ = input.;\n    return r;\n}\n\n/// Comparison")),
    ("generic_hover_base_param", H, "action: []const u8, ba§se: R, input", None),
    ("generic_fields_on_r", C, "    _ = r.§;\n    return r;\n}\n\n/// Comparison", ("    return r;\n}\n\n/// Comparison", "    _ = r.;\n    return r;\n}\n\n/// Comparison")),
    ("generic_members_of_R", C, "    _ = R.§;\n    return r;\n}\n\n/// Comparison", ("    return r;\n}\n\n/// Comparison", "    _ = R.;\n    return r;\n}\n\n/// Comparison")),
    ("generic_hover_action_value", H, "const §a = comptime find(R, action);\n    var r", None),
    ("generic_fields_on_action", C, "    _ = a.§;\n    return r;\n}\n\n/// Comparison", ("    return r;\n}\n\n/// Comparison", "    _ = a.;\n    return r;\n}\n\n/// Comparison")),
    ("generic_hover_loop_capture", H, "inline for (a.accept) |§f| @field(r", None),
    ("generic_hover_accept_field", H, "inline for (a.acc§ept) |f| @field(r", None),
    ("generic_hover_hook_capture", H, "if (a.after) |§h| @field", None),
    ("generic_hover_Generated_call", H, "input: Gener§ated(R, inputShape", None),
    ("generic_def_Generated", D, "input: Gener§ated(R, inputShape", None),
    ("generic_def_inputShape", D, "Generated(R, input§Shape(R, action).name)", None),
    ("generic_hover_inputShape_name", H, "inputShape(R, action).na§me)) R {", None),
    ("generic_sig_run", S, "return run(§);", ("    return r;\n}\n\n/// Comparison", "    return run();\n}\n\n/// Comparison")),
    ("loop_hover_action_capture", H, "for (R.actions) |§a| if", None),
    ("loop_fields_on_action", C, "std.mem.eql(u8, a.§, action)", ("std.mem.eql(u8, a.name, action)", "std.mem.eql(u8, a., action)")),
    ("loop_hover_field_capture", H, "for (a.accept, 0..) |§f, i| {", None),
    ("shape_fields", C, "return .{ .§ };\n}\n\npub fn pascal", ('return .{ .name = pascal(action) ++ "Input", .field_names = &n, .field_types = &t };', "return .{ . };")),
    ("api_members_in_zava", C, "    _ = api.§;\n    return r;\n}\n\n/// Comparison", ("    return r;\n}\n\n/// Comparison", "    _ = api.;\n    return r;\n}\n\n/// Comparison")),
    ("domain_members_in_zava", C, "    _ = domain.§;\n    return r;\n}\n\n/// Comparison", ("    return r;\n}\n\n/// Comparison", "    _ = domain.;\n    return r;\n}\n\n/// Comparison")),
    # the same behaviour against concrete generated types
    ("concrete_hover_input_param", H, "base: domain.Author, in§put: api.Author.RegisterInput) domain.Author {", None),
    ("concrete_fields_on_input", C, "r.email = input.§;", ("r.email = input.email;", "r.email = input.;")),
    ("concrete_fields_on_r", C, "    r.§;\n    r.name = input.name;", ("    r.email = input.email;", "    r.;")),
    ("concrete_hover_field", H, "r.email = input.em§ail;", None),
    ("concrete_def_field", D, "r.email = input.em§ail;", None),
    ("concrete_def_input_type", D, "input: api.Author.Register§Input) domain.Author {", None),
    ("concrete_def_record_field", D, "r.em§ail = input.email;", None),
    # half-way: Generated() called with concrete arguments
    ("mixed_hover_input_param", H, "in§put: Generated(domain.Author, \"RegisterInput\")", None),
    ("mixed_fields_on_input", C, "return input.§;", ("return input.email;", "return input.;")),
    # a concrete alias next to the generic code
    ("alias_hover", H, "const Register§Input = api.Author.RegisterInput;", None),
    ("alias_fields_on_input", C, "return in.§;", ("return in.name;", "return in.;")),
]

GEN = [
    ("gen_hover_resource_capture", H, "inline for (domain.resources) |§R| {", None),
    ("gen_members_of_R", C, "    _ = R.§;\n        inline for (R.actions)", ("        inline for (R.actions)", "    _ = R.;\n        inline for (R.actions)")),
    ("gen_hover_action_capture", H, "inline for (R.actions) |§a| {", None),
    ("gen_hover_shape", H, "const sh§ape = comptime zava.inputShape", None),
    ("gen_fields_on_shape", C, "for (shape.§, shape.field_types)", ("for (shape.field_names, shape.field_types)", "for (shape., shape.field_types)")),
    ("gen_domain_members", C, "inline for (domain.§) |R| {", ("inline for (domain.resources) |R| {", "inline for (domain.) |R| {")),
]

Q1_FILES = (("app.zig", APP), ("domain.zig", DOMAIN), ("zava.zig", ZAVA), ("gen.zig", GEN))

FRESH_OLD = '.{ .name = "rename", .accept = &.{.name} },'
FRESH_NEW = '.{ .name = "rename", .accept = &.{ .name, .email } },'
FRESH_MARK = "set name = $1, email = $2"
FRESH_PROBE = ("app.zig", C, "api.Author.rename(a, .{ .§ });", ('api.Author.rename(a, .{ .name = "bob" });', "api.Author.rename(a, .{ .§ });"))


def prepare(args, name, mode, check, prebuilt, subdir="q1", graph="stub"):
    ws = os.path.join(args.scratch, name)
    shutil.rmtree(ws, ignore_errors=True)
    shutil.copytree(os.path.join(args.src, subdir), ws)
    for junk in (".zig-cache", "zig-out", "generated"):
        shutil.rmtree(os.path.join(ws, junk), ignore_errors=True)
    bz = os.path.join(ws, "build.zig")
    if os.path.exists(bz) and mode:
        text = open(bz).read()
        text = re.sub(r"^const mode: Mode = \.\w+;", f"const mode: Mode = .{mode};", text, flags=re.M)
        text = re.sub(r"^const with_check = \w+;", f"const with_check = {'true' if check else 'false'};", text, flags=re.M)
        text = re.sub(r"^const graph: Graph = \.\w+;", f"const graph: Graph = .{graph};", text, flags=re.M)
        open(bz, "w").write(text)
    build_secs = None
    if prebuilt:
        t = time.time()
        subprocess.run([args.zig, "build"], cwd=ws, check=True, capture_output=True)
        build_secs = round(time.time() - t, 2)
    return os.path.realpath(ws), build_secs


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


def run_features(args, raw, summary, name, mode, check, bos, prebuilt, full, graph="stub"):
    """Start ZLS on a workspace and measure resolution of the generated module."""
    ws, build_secs = prepare(args, name, mode, check, prebuilt, graph=graph)
    label = f"features[{name}] mode={mode} check_step={check} enable_build_on_save={bos} prebuilt_cache={prebuilt} graph={graph}"
    summary.append(f"===== {label} =====")
    if build_secs is not None:
        summary.append(f"manual `zig build` before starting ZLS took {build_secs}s")
    rec = raw["features"][name] = {"mode": mode, "check": check, "build_on_save": bos, "prebuilt": prebuilt, "probes": {}}
    s = Session(args, ws, bos)
    raw.setdefault("server_info", s.init.get("serverInfo"))
    s.open("app.zig")
    first = lambda: labels(s.probe("app.zig", C, *APP[1][2:])[1])
    got, secs = wait_until(first, args.resolve_wait)
    rec["seconds_until_api_resolves"] = secs if got else None
    summary.append(f"time from didOpen(app.zig) until `api.Author.` completes: {str(secs) + 's' if got else 'NEVER within ' + str(secs) + 's'}")
    summary.append(f"generated files on disk after ZLS started: {json.dumps(generated_files(ws))}")
    rec["generated_files"] = generated_files(ws)
    files = Q1_FILES if full else (("app.zig", APP[:6] + [p for p in APP if p[0] in ("hover_fn_register", "sig_register", "def_fn_register")]),)
    for fname, probes in files:
        if fname not in s.docs:
            s.open(fname)
            time.sleep(1.0)
        summary.append(f"--- {fname}")
        for pname, method, anchor, edit in probes:
            pos, result = s.probe(fname, method, anchor, edit)
            rec["probes"][f"{fname}:{pname}"] = {"method": method, "anchor": anchor, "edited": bool(edit), "position": pos, "result": result}
            summary.append(f"[{pname}] {method.split('/')[1]} @ {anchor!r}\n    -> {digest(method, result, s.base)}")
    if full:
        text = s.docs["app.zig"][0]
        lines = text.split("\n")
        hints = s.c.request("textDocument/inlayHint", {"textDocument": {"uri": s.base + "app.zig"}, "range": {"start": {"line": 0, "character": 0}, "end": {"line": len(lines), "character": 0}}})
        rec["inlay_hints"] = hints
        summary.append(f"--- app.zig inlay hints: {len(hints or [])}")
        for h in hints or []:
            lab = h["label"] if isinstance(h["label"], str) else "".join(p["value"] for p in h["label"])
            ln = h["position"]["line"]
            summary.append(f"    L{ln + 1}:{h['position']['character'] + 1} kind={h.get('kind')} {lab!r}   | {lines[ln].strip()}")
        time.sleep(3)
        for fname in s.docs:
            d = s.c.diagnostics(s.base + fname)
            summary.append(f"diagnostics {fname}: {'never published' if d is None else json.dumps([x['message'] for x in d])}")
    rec["registrations"] = [r for r in s.c.server_requests() if r["method"] == "client/registerCapability"]
    rec["log"] = s.c.logs()
    summary.append("ZLS warnings/errors: " + (json.dumps(bad_logs(s)) if bad_logs(s) else "none"))
    info = [n["params"]["message"] for n in s.c.logs() if "uild" in n["params"]["message"]]
    summary.append("ZLS log lines mentioning build: " + json.dumps(info[:12]))
    s.close()
    summary.append("")


def run_broken(args, raw, summary):
    """The declaration does not compile when the editor starts."""
    name = "broken_domain"
    ws, _ = prepare(args, name, "capture", True, False)
    p = os.path.join(ws, "domain.zig")
    good = open(p).read()
    bad = good.replace(FRESH_OLD, '.{ .name = "rename", .accept = &.{.nmae} },')
    assert bad != good
    open(p, "w").write(bad)
    summary.append("===== features[broken_domain] mode=capture check_step=True enable_build_on_save=None, clean cache, declaration has a misspelled attribute =====")
    s = Session(args, ws, None)
    s.open("app.zig")
    s.open("domain.zig")
    first = lambda: labels(s.probe("app.zig", C, *APP[1][2:])[1])
    got, secs = wait_until(first, 40)
    summary.append(f"`api.Author.` completes: {'yes after ' + str(secs) + 's: ' + str(got) if got else 'NEVER within ' + str(secs) + 's'}")
    time.sleep(3)
    diags = {}
    for n in s.c.notifications:
        # app.zig is skipped: its diagnostics come from the driver's own incomplete probe text
        if n.get("method") == "textDocument/publishDiagnostics" and n["params"]["diagnostics"] and not n["params"]["uri"].endswith("/app.zig"):
            diags[n["params"]["uri"].replace(s.base, "")] = [f"{d['range']['start']['line'] + 1}:{d['range']['start']['character'] + 1} {d['message']}" for d in n["params"]["diagnostics"]]
    summary.append("diagnostics published: " + json.dumps(diags, indent=1))
    # fix it, save, see whether the editor recovers by itself
    fixed = good
    before = snap(ws)
    s.save_to_disk("domain.zig", fixed)
    got, secs = wait_until(first, 30)
    summary.append(f"after fixing and saving domain.zig: `api.Author.` completes: {'yes after ' + str(secs) + 's' if got else 'NEVER within ' + str(secs) + 's'}")
    if not got:
        _, ch = s.watched_events(before)
        got, secs = wait_until(first, 8)
        summary.append(f"  then didChangeWatchedFiles ({len(ch)} events): {'yes after ' + str(secs) + 's' if got else 'still no'}")
    if not got:
        s.c.notify("textDocument/didSave", {"textDocument": {"uri": s.base + "build.zig"}})
        got, secs = wait_until(first, 40)
        summary.append(f"  then didSave(build.zig): {'yes after ' + str(secs) + 's' if got else 'still no'}")
    if not got:
        s.close()
        s = Session(args, ws, None)
        s.open("app.zig")
        got, secs = wait_until(first, 40)
        summary.append(f"  then restart ZLS: {'yes after ' + str(secs) + 's' if got else 'still no'}")
    raw["features"][name] = {"diagnostics": diags, "log": s.c.logs()}
    summary.append("ZLS warnings/errors: " + (json.dumps(bad_logs(s)) if bad_logs(s) else "none"))
    s.close()
    summary.append("")


def run_fresh(args, raw, summary, name, mode, check, bos, graph="stub"):
    """Edit the declaration, save, and see what it takes for app.zig to see the new field."""
    ws, _ = prepare(args, "fresh-" + name, mode, check, False, graph=graph)
    label = f"freshness[{name}] mode={mode} check_step={check} enable_build_on_save={bos} graph={graph}"
    summary.append(f"===== {label} =====")
    rec = raw["freshness"][name] = {"mode": mode, "check": check, "build_on_save": bos, "steps": []}
    s = Session(args, ws, bos)
    s.open("app.zig")
    fname, method, anchor, edit = FRESH_PROBE
    comp = lambda: labels(s.probe(fname, method, anchor, edit)[1])
    got, secs = wait_until(comp, args.resolve_wait)
    summary.append(f"before the edit: rename input completes {got} (api resolved after {secs}s)")
    if not got:
        summary.append("api never resolved; skipping")
        rec["log"] = s.c.logs()
        s.close()
        summary.append("")
        return
    time.sleep(2)  # let build-on-save finish its first cycle
    bos_running = any("Build-On-Save is running" in n["params"]["message"] for n in s.c.logs())
    summary.append(f"ZLS logged 'Build-On-Save is running': {bos_running}")
    summary.append(f"generated files before: {json.dumps(generated_files(ws))}")
    dom = s.open("domain.zig")
    new_dom = dom.replace(FRESH_OLD, FRESH_NEW)
    assert new_dom != dom
    fresh = lambda: "email" in comp()

    def step(label, action, wait):
        t = time.time()
        extra = action()
        ok, secs = wait_until(fresh, wait)
        # when (if ever) did a regenerated file reach the disk
        gf = generated_files(ws)
        line = f"  {label}: completion shows `email`: {'YES after ' + str(secs) + 's' if ok else 'no (waited ' + str(secs) + 's)'}"
        if extra:
            line += f" [{extra}]"
        line += f"; fresh generated file on disk: {'yes' if 'FRESH' in gf.values() else 'no'}"
        summary.append(line)
        rec["steps"].append({"step": label, "fresh": bool(ok), "seconds": secs, "generated_files": gf, "extra": extra})
        return bool(ok)

    before = snap(ws)
    done = step("1. edit domain.zig in the buffer only (didChange, unsaved)", lambda: s.change("domain.zig", new_dom), 4)

    def wait_disk():
        s.save_to_disk("domain.zig", new_dom)
        ok, secs = wait_until(lambda: "FRESH" in generated_files(ws).values(), 25)
        return f"regenerated file appeared on disk after {secs}s" if ok else f"no regenerated file on disk after {secs}s"

    if not done:
        done = step("2. save domain.zig (write + didSave), no file-watcher events", wait_disk, 5)
    if not done:
        def act():
            nonlocal before
            before, ch = s.watched_events(before)
            return f"{len(ch)} events: " + ", ".join(c["uri"].replace(s.base, "") + ":" + str(c["type"]) for c in ch[:6])
        done = step("3. editor file watcher reports changed/created *.zig (didChangeWatchedFiles)", act, 6)
    if not done and mode == "source_tree":
        def act():
            # ZLS 0.17.0 ignores `Changed` for unopened files (zigtools/zls#3305) but honours `Deleted`.
            uri = s.base + "generated/api.zig"
            s.c.notify("workspace/didChangeWatchedFiles", {"changes": [{"uri": uri, "type": 3}]})
            s.c.notify("workspace/didChangeWatchedFiles", {"changes": [{"uri": uri, "type": 1}]})
        done = step("3b. file watcher reports generated/api.zig as Deleted then Created (as if the generator replaced the file)", act, 6)
    if not done:
        def act():
            nonlocal before
            t = time.time()
            r = subprocess.run([args.zig, "build"], cwd=ws, capture_output=True)
            before, ch = s.watched_events(before)
            return f"zig build exit {r.returncode} in {round(time.time() - t, 2)}s, {len(ch)} watcher events"
        done = step("4. run `zig build` by hand, then file-watcher events", act, 8)
    if not done:
        def act():
            # touch without changing content, as an editor "save" of build.zig would
            os.utime(os.path.join(ws, "build.zig"))
            s.c.notify("textDocument/didSave", {"textDocument": {"uri": s.base + "build.zig"}})
        done = step("5. save build.zig unchanged (didSave -> ZLS reloads the build configuration)", act, 40)
    if not done:
        def act():
            nonlocal s
            rec["log_before_restart"] = s.c.logs()
            s.close()
            s = Session(args, ws, bos)
            s.open("app.zig")
        done = step("6. restart ZLS", act, args.resolve_wait)
    if done:
        pos, r = s.probe("app.zig", D, "api.Author.ren§ame(a", None)
        summary.append(f"  go-to-definition of rename now: {digest(D, r, s.base)}")
        pos, r = s.probe("app.zig", H, "api.Author.ren§ame(a", None)
        summary.append(f"  hover on rename now: {digest(H, r, s.base)}")
    summary.append(f"generated files after: {json.dumps(generated_files(ws))}")
    rec["log"] = s.c.logs()
    summary.append("ZLS warnings/errors: " + (json.dumps(bad_logs(s)) if bad_logs(s) else "none"))
    s.close()
    summary.append("")


# ---------------------------------------------------------------- question 2

# Probes for the Author declaration; the same anchors exist in every variant.
# Positions are searched in the text before `pub const Post`, so that the second
# resource can repeat the same lines.
Q2_AUTHOR = [
    ("option_names", C, "        .§\n        .primary_key = .id,", ('        .table = "authors",\n', '        .\n')),
    ("primary_key_value", C, ".primary_key = .§,", (".primary_key = .id,", ".primary_key = .,")),
    ("accept_member_first", C, '.name = "rename", .accept = &.{.§} },', ('.name = "rename", .accept = &.{.name} },', '.name = "rename", .accept = &.{.} },')),
    ("accept_member_second", C, ".accept = &.{ .email, .§ }, .after", (".accept = &.{ .email, .name }, .after", ".accept = &.{ .email, . }, .after")),
    ("action_option_names", C, '.{ .name = "rename", .§ },', ('.{ .name = "rename", .accept = &.{.name} },', '.{ .name = "rename", . },')),
    ("action_kind_value", C, ".kind = .§, .accept = &.{ .email", (".kind = .create, .accept = &.{ .email", ".kind = ., .accept = &.{ .email")),
    ("after_decl_name", C, ".after = .§ },", (".after = .welcome },", ".after = . },")),
    ("after_identifier_in_scope", C, ".after = wel§ },", (".after = .welcome },", ".after = wel },")),
    # keyed attributes block (variants A, B, C)
    ("attributes_block_keys", C, ".attributes = .{\n            .§\n", ('            .email = .{ .unique = true, .column = "email_address" },\n', "            .\n")),
    ("attribute_option_names", C, ".email = .{ .unique = true, .§ },", ('.email = .{ .unique = true, .column = "email_address" },', ".email = .{ .unique = true, . },")),
    ("hover_attributes_key", H, "            .em§ail = .{ .unique", None),
    ("hover_attribute_option", H, ".email = .{ .uni§que = true", None),
    ("def_attributes_key", D, "            .em§ail = .{ .unique", None),
    ("def_attribute_option", D, ".email = .{ .uni§que = true", None),
    # attributes as a list (variant D)
    ("attribute_entry_field_value", C, ".{ .field = .§, .unique = true", (".{ .field = .email, .unique = true", ".{ .field = ., .unique = true")),
    ("attribute_entry_option_names", C, ".{ .field = .email, .§ },", ('.{ .field = .email, .unique = true, .column = "email_address" },', ".{ .field = .email, . },")),
    ("hover_attribute_entry_field", H, ".{ .field = .em§ail, .unique", None),
    ("hover_attribute_entry_option", H, ".field = .email, .uni§que = true", None),
    ("def_attribute_entry_field", D, ".{ .field = .em§ail, .unique", None),
    ("def_attribute_entry_option", D, ".field = .email, .uni§que = true", None),
    # hover and go-to-definition on the rest
    ("hover_resource_decl", H, "pub const reso§urce", None),
    ("hover_options_call", H, "pub const resource: zava.Opt§ions", None),
    ("hover_resource_fn_call", H, "pub const resource = zava.reso§urce", None),
    ("hover_option_table", H, '.tab§le = "authors"', None),
    ("hover_option_primary_key", H, ".prim§ary_key = ", None),
    ("hover_primary_key_value", H, ".primary_key = .i§d", None),
    ("hover_action_accept", H, '"register", .kind = .create, .acc§ept = ', None),
    ("hover_accept_member", H, ".accept = &.{ .em§ail, .name }", None),
    ("hover_after_option", H, ".name }, .af§ter = .welcome", None),
    ("hover_after_value", H, ".after = .wel§come", None),
    ("def_option_primary_key", D, ".prim§ary_key = ", None),
    ("def_primary_key_value", D, ".primary_key = .i§d", None),
    ("def_accept_member", D, ".accept = &.{ .em§ail, .name }", None),
    ("def_after_value", D, ".after = .wel§come", None),
]

# Variant E only (the flattened declaration).
Q2_FLAT = [
    ("flat_action_option_names", C, 'const rename: Action = .{ .name = "rename", .§ };', ('const rename: Action = .{ .name = "rename", .accept = &[_]Field{.name} };', 'const rename: Action = .{ .name = "rename", . };')),
    ("flat_action_kind_value", C, '"register", .kind = .§, .accept', ('"register", .kind = .create, .accept', '"register", .kind = ., .accept')),
    ("flat_accept_member_anon", C, ".accept = &.{ .email, .§ }, .after = .welcome };", (".accept = &.{ .email, .name }, .after = .welcome };", ".accept = &.{ .email, . }, .after = .welcome };")),
    ("flat_accept_member_typed_array", C, ".accept = &[_]Field{.§} };", (".accept = &[_]Field{.name} };", ".accept = &[_]Field{.} };")),
    ("flat_after_value", C, ".name }, .after = .§ };", (".name }, .after = .welcome };", ".name }, .after = . };")),
    ("flat_attr_option_names", C, "const email_options: Attr = .{ .field = .email, .§ };", ('const email_options: Attr = .{ .field = .email, .unique = true, .column = "email_address" };', "const email_options: Attr = .{ .field = .email, . };")),
    ("flat_attr_field_value", C, "const email_options: Attr = .{ .field = .§, .unique", ("const email_options: Attr = .{ .field = .email, .unique", "const email_options: Attr = .{ .field = ., .unique")),
    ("flat_actions_list_identifier", C, ".actions = &.{ register, ren§ },", (".actions = &.{ register, rename },", ".actions = &.{ register, ren },")),
    ("flat_hover_after_value", H, ".name }, .after = .wel§come };", None),
    ("flat_def_after_value", D, ".name }, .after = .wel§come };", None),
    ("flat_hover_accept_member", H, ".accept = &.{ .em§ail, .name }, .after", None),
    ("flat_def_attr_field_value", D, "const email_options: Attr = .{ .field = .em§ail, .unique", None),
]

# The second resource: a few probes with anchors unique to Post.
Q2_POST = [
    ("post_primary_key_value", C, '"posts",\n        .primary_key = .§,', ('"posts",\n        .primary_key = .id,', '"posts",\n        .primary_key = .,')),
    ("post_accept_member", C, ".accept = &.{ .author_id, .§ }, .after", (".accept = &.{ .author_id, .title }, .after", ".accept = &.{ .author_id, . }, .after")),
    ("post_after_decl_name", C, ".after = .§ },\n            .{ .name = \"publish\"", (".after = .stamp },", ".after = . },")),
    ("post_attributes_block_keys", C, ".attributes = .{\n            .§\n        },\n    }", ('            .title = .{ .column = "headline" },\n', "            .\n")),
    ("post_attribute_entry_field_value", C, ".{ .field = .§, .column = \"headline\"", ('.{ .field = .title, .column = "headline"', '.{ .field = ., .column = "headline"')),
    ("post_hover_accept_member", H, ".accept = &.{ .author_id, .ti§tle }", None),
    ("post_flat_after_value", C, ".title }, .after = .§ };", (".title }, .after = .stamp };", ".title }, .after = . };")),
    ("post_flat_attr_field_value", C, "const title_options: Attr = .{ .field = .§, .column", ("const title_options: Attr = .{ .field = .title, .column", "const title_options: Attr = .{ .field = ., .column")),
]

EXTRAS = [
    ("e1_FieldType_string_completion", C, 'const E1a = @FieldType(Author, "§");', ('@FieldType(Author, "email");', '@FieldType(Author, "");')),
    ("e1_field_string_completion", C, 'return @field(a, "§");', ('return @field(a, "name");', 'return @field(a, "");')),
    ("e1_hasField_string_completion", C, 'const e1d = @hasField(Author, "§");', ('@hasField(Author, "email");', '@hasField(Author, "");')),
    ("e1_hover_FieldType_alias", H, "const E§1a = @FieldType", None),
    ("e1_hover_value_of_FieldType", H, "const e§1b: E1a", None),
    ("e1_def_FieldType_string", D, '@FieldType(Author, "em§ail")', None),
    ("e1_def_field_string", D, 'return @field(a, "na§me");', None),
    ("e2_hover_generic_FieldType", H, 'const e§2: Default(Author, "id")', None),
    ("e2_literal_fields_generic", C, 'const e2: Default(Author, "id") = .{ .§ };', ('const e2: Default(Author, "id") = .{ .value = 1 };', 'const e2: Default(Author, "id") = .{ . };')),
    ("e2_hover_direct_field", H, "const e2_direct: struct { val§ue: @FieldType", None),
    ("e3_fn_value_members", C, "const e3: Hooked = .{ .after = Author.§ };", ("const e3: Hooked = .{ .after = Author.welcome };", "const e3: Hooked = .{ .after = Author. };")),
    ("e4_decl_literal_members", C, "const e4: AuthorField = .§;", ("const e4: AuthorField = .email;", "const e4: AuthorField = .;")),
    ("e4_def_decl_literal", D, "const e4: AuthorField = .em§ail;", None),
    ("e5_FieldEnum_of_union", C, "const e5: std.meta.FieldEnum(AuthorAttr) = .§;", ("const e5: std.meta.FieldEnum(AuthorAttr) = .email;", "const e5: std.meta.FieldEnum(AuthorAttr) = .;")),
    ("e5_Tag_of_union", C, "const e5_tag: std.meta.Tag(AuthorAttr) = .§;", ("const e5_tag: std.meta.Tag(AuthorAttr) = .email;", "const e5_tag: std.meta.Tag(AuthorAttr) = .;")),
    ("e5_union_value_members", C, "const e5_value: AuthorAttr = .{ .§ };", ('const e5_value: AuthorAttr = .{ .email = "x" };', "const e5_value: AuthorAttr = .{ . };")),
]


def run_q2(args, raw, summary):
    ws, _ = prepare(args, "q2", None, None, False, subdir="q2")
    s = Session(args, ws, False)
    variants = sorted(f for f in os.listdir(ws) if f.startswith("domain_") and f.endswith(".zig"))
    for fname in variants + ["extras.zig"]:
        text = s.open(fname)
        time.sleep(1.5)
        summary.append(f"===== q2 {fname} =====")
        summary.append("variant: " + " ".join(l[4:] for l in text.split("\n")[:8] if l.startswith("//! ")))
        cut = text.index("pub const Post = struct") if "pub const Post = struct" in text else len(text)
        groups = ((EXTRAS, 0, len(text)),) if fname == "extras.zig" else ((Q2_AUTHOR + Q2_FLAT, 0, cut), (Q2_POST, cut, len(text)))
        for probes, lo, hi in groups:
            for pname, method, anchor, edit in probes:
                part = text[lo:hi]
                if edit:
                    if part.count(edit[0]) != 1:
                        continue  # this probe belongs to another variant
                    part = part.replace(edit[0], edit[1].replace(M, ""))
                elif part.count(anchor.replace(M, "")) != 1:
                    continue
                edited = text[:lo] + part + text[hi:]
                s.change(fname, edited)
                rel = pos_of(part, anchor)
                off = lo + len("\n".join(part.split("\n")[:rel["line"]])) + (1 if rel["line"] else 0) + rel["character"]
                pos = {"line": edited.count("\n", 0, off), "character": off - (edited.rfind("\n", 0, off) + 1)}
                params = {"textDocument": {"uri": s.base + fname}, "position": pos}
                if method == C:
                    ch = anchor[anchor.index(M) - 1]
                    params["context"] = {"triggerKind": 2, "triggerCharacter": ch} if ch in '."' else {"triggerKind": 1}
                result = s.c.request(method, params)
                s.change(fname, text)
                raw["q2"][f"{fname}:{pname}"] = {"method": method, "anchor": anchor, "edited": bool(edit), "position": pos, "result": result}
                summary.append(f"[{pname}] {method.split('/')[1]} @ {anchor!r}\n    -> {digest(method, result, s.base)}")
        summary.append("")
    raw["q2_log"] = s.c.logs()
    summary.append("ZLS warnings/errors: " + (json.dumps(bad_logs(s)) if bad_logs(s) else "none"))
    s.close()
    summary.append("")


FEATURE_CONFIGS = [
    # name, mode, check step, enable_build_on_save, prebuilt cache, full probe set
    ("capture_check_clean", "capture", True, None, False, True),
    ("capture_check_prebuilt", "capture", True, None, True, False),
    ("capture_nocheck_bosoff_clean", "capture", False, False, False, False),
    ("outarg_check_clean", "outarg", True, None, False, False),
    ("writefiles_check_clean", "writefiles", True, None, False, False),
    ("sourcetree_check_clean", "source_tree", True, None, False, False),
    ("sourcetree_nocheck_bosoff_clean", "source_tree", False, False, False, False),
    ("capture_check_clean_nostub", "capture", True, None, False, True, "no_stub"),
    ("capture_check_clean_realfirst", "capture", True, None, False, True, "real_first"),
]

FRESH_CONFIGS = [
    # name, mode, check step, enable_build_on_save
    ("capture_nocheck_bosoff", "capture", False, False),
    ("capture_nocheck_bosdefault", "capture", False, None),
    ("capture_nocheck_boson", "capture", False, True),
    ("capture_check_bosoff", "capture", True, False),
    ("capture_check_bosdefault", "capture", True, None),
    ("outarg_check_bosdefault", "outarg", True, None),
    ("writefiles_check_bosdefault", "writefiles", True, None),
    ("sourcetree_check_bosdefault", "source_tree", True, None),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zls", required=True)
    ap.add_argument("--zig", required=True)
    ap.add_argument("--src", required=True)
    ap.add_argument("--scratch", required=True)
    ap.add_argument("--out", default="results")
    ap.add_argument("--only", default="features,broken,fresh,q2")
    ap.add_argument("--configs", default="")
    ap.add_argument("--resolve-wait", type=float, default=90.0)
    args = ap.parse_args()
    args.src = os.path.realpath(args.src)
    os.makedirs(args.scratch, exist_ok=True)
    args.scratch = os.path.realpath(args.scratch)
    os.makedirs(args.out, exist_ok=True)
    only = set(args.only.split(","))
    configs = set(filter(None, args.configs.split(",")))

    raw = {"zls_version": subprocess.check_output([args.zls, "--version"]).decode().strip(),
           "zig_version": subprocess.check_output([args.zig, "version"]).decode().strip(),
           "features": {}, "freshness": {}, "q2": {}}
    summary = [f"ZLS {raw['zls_version']}  Zig {raw['zig_version']}", ""]

    if "features" in only:
        for cfg in FEATURE_CONFIGS:
            if configs and cfg[0] not in configs:
                continue
            run_features(args, raw, summary, *cfg)
            print("\n".join(summary[-3:]), file=sys.stderr)
    if "broken" in only and not configs:
        run_broken(args, raw, summary)
    if "fresh" in only:
        for cfg in FRESH_CONFIGS:
            if configs and cfg[0] not in configs:
                continue
            run_fresh(args, raw, summary, *cfg)
    if "q2" in only and not configs:
        run_q2(args, raw, summary)

    def scrub(text):
        return text.replace(args.scratch, "/SCRATCH").replace(os.path.expanduser("~"), "~")

    tag = "" if only >= {"features", "broken", "fresh", "q2"} and not configs else "-partial"
    open(os.path.join(args.out, f"raw{tag}.json"), "w").write(scrub(json.dumps(raw, indent=1)))
    open(os.path.join(args.out, f"summary{tag}.txt"), "w").write(scrub("\n".join(summary) + "\n"))
    print(scrub("\n".join(summary)))


if __name__ == "__main__":
    sys.exit(main())
