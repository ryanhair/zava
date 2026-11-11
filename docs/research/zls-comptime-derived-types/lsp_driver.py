#!/usr/bin/env python3
"""Drive ZLS over LSP (JSON-RPC on stdio) and record the raw responses.

Usage:
    python3 lsp_driver.py --zls /path/to/zls --zig /path/to/zig \
        --workspace /path/to/copy/of/this/dir --out results

The workspace must contain derived.zig, generated.zig, variations.zig,
derived_bad.zig, generated_bad.zig and build.zig. Run it against a scratch copy: build-on-save
creates .zig-cache there.

Each probe names a cursor position by an anchor string containing the marker
character '§'. If the probe has an "edit" (old, new) pair, `old` is replaced
by `new` in the document (sent as a full-text didChange) before the request,
and the anchor is searched in the edited text. Positions are therefore derived
from the source text, never hard-coded.

Outputs:
    <out>/raw.json      every request and full raw response
    <out>/summary.txt   a compact human-readable digest
"""
import argparse
import json
import os
import queue
import subprocess
import sys
import threading
import time

M = "§"


class Client:
    def __init__(self, zls, config):
        self.proc = subprocess.Popen([zls], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
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
        """Latest publishDiagnostics for uri, or None if never published."""
        with self.cv:
            for n in reversed(self.notifications):
                if n.get("method") == "textDocument/publishDiagnostics" and n["params"]["uri"] == uri:
                    return n["params"]["diagnostics"]
        return None

    def close(self):
        self.request("shutdown", None, timeout=10)
        self.notify("exit", None)
        try:
            self.proc.wait(5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


CAPS = {
    "general": {"positionEncodings": ["utf-16"]},
    "workspace": {"configuration": True, "workspaceFolders": True, "didChangeConfiguration": {"dynamicRegistration": False}},
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


# (name, method, anchor, edit)
C, H, D, T, S = (
    "textDocument/completion",
    "textDocument/hover",
    "textDocument/definition",
    "textDocument/typeDefinition",
    "textDocument/signatureHelp",
)

DERIVED = [
    # --- completion of field names inside the input literal
    ("literal_fields_author_register", C, "run(Author, .register, .{ .§ });",
     ('run(Author, .register, .{ .email = "x", .name = "y" });', "run(Author, .register, .{ .§ });")),
    ("literal_fields_post_draft", C, "run(Post, .draft, .{ .§ });",
     ('run(Post, .draft, .{ .author_id = 1, .title = "t", .body = null });', "run(Post, .draft, .{ .§ });")),
    ("literal_fields_typed_decl", C, "var in: Input(Author, .register) = .{ .§ };",
     ('var in: Input(Author, .register) = .{ .email = "a@b.c", .name = "ann" };', "var in: Input(Author, .register) = .{ .§ };")),
    # --- completion of the action name
    ("action_name_author", C, "const lit = try run(Author, .§, .{});",
     ('const lit = try run(Author, .register, .{ .email = "x", .name = "y" });', "const lit = try run(Author, .§, .{});")),
    ("action_name_author_unclosed", C, "const lit = try run(Author, .§",
     ('const lit = try run(Author, .register, .{ .email = "x", .name = "y" });', "const lit = try run(Author, .§")),
    ("action_name_post", C, "const d = try run(Post, .§, .{});",
     ('const d = try run(Post, .draft, .{ .author_id = 1, .title = "t", .body = null });', "const d = try run(Post, .§, .{});")),
    ("action_name_in_type_expr", C, "var in: Input(Author, .§) = undefined;",
     ('var in: Input(Author, .register) = .{ .email = "a@b.c", .name = "ann" };', "var in: Input(Author, .§) = undefined;")),
    # --- hover
    ("hover_input_arg_at_call", H, "run(Author, .register, i§n);", None),
    ("hover_var_of_derived_type", H, "var i§n: Input(Author, .register)", None),
    ("hover_hook_param", H, "fn normalize(in§put: *Input(Author, .register))", None),
    ("hover_run_param_input", H, "in§put: Input(R, action)) Error!R {\n    var r", None),
    ("hover_run_result", H, "const §a = try run(Author, .register, in);", None),
    ("hover_run_callee", H, "const a = try r§un(Author, .register, in);", None),
    ("hover_derived_type_expr", H, "var in: Inp§ut(Author, .register)", None),
    ("hover_action_enum_literal", H, "const a = try run(Author, .regi§ster, in);", None),
    ("hover_field_on_derived_var", H, "_ = in.em§ail;", None),
    ("hover_post_input_var", H, "const post_§in: Input(Post, .publish)", None),
    ("hover_post_result", H, "const §p = try run(Post, .publish, post_in);", None),
    # --- completion of fields on variables
    ("fields_on_derived_var", C, "_ = in.§;", ("_ = in.email;", "_ = in.§;")),
    ("fields_on_run_result", C, "_ = a.§;", ("_ = a.email;", "_ = a.§;")),
    ("fields_on_post_input_var", C, "_ = post_in.§;", ("_ = p.title;", "_ = post_in.§;")),
    ("fields_on_post_result", C, "_ = p.§;", ("_ = p.title;", "_ = p.§;")),
    ("fields_on_hook_param", C, "input.§;\n}\n\nfn normalizeAlias", ('input.name = "Ann";\n}\n\nfn normalizeAlias', "input.§;\n}\n\nfn normalizeAlias")),
    # --- go to definition
    ("def_derived_type", D, "var in: Inp§ut(Author, .register)", None),
    ("typedef_derived_var", T, "_ = i§n.email;", None),
    ("def_field_of_derived", D, "_ = in.em§ail;", None),
    ("def_field_in_literal", D, 'run(Author, .register, .{ .em§ail = "x"', None),
    ("def_action_enum_literal", D, "const a = try run(Author, .regi§ster, in);", None),
    ("def_field_of_run_result", D, "_ = a.em§ail;", None),
    # --- signature help
    ("sig_run_third_arg", S, "const a = try run(Author, .register, §in);", None),
    ("sig_run_empty", S, "const a = try run(§);", ("const a = try run(Author, .register, in);", "const a = try run(§);")),
    # --- variation: named alias
    ("alias_hover_var", H, "var alia§sed: RegisterInput", None),
    ("alias_hover_decl", H, "pub const Register§Input = Input(Author, .register);", None),
    ("alias_fields_on_var", C, "_ = aliased.§;", ("_ = aliased.email;", "_ = aliased.§;")),
    ("alias_literal_fields", C, "var aliased: RegisterInput = .{ .§ };",
     ('var aliased: RegisterInput = .{ .email = "a@b.c", .name = "ann" };', "var aliased: RegisterInput = .{ .§ };")),
    ("alias_def_field", D, "_ = aliased.em§ail;", None),
    ("alias_typedef_var", T, "_ = alia§sed.email;", None),
    # --- variation: namespace function
    ("ns_hover_var", H, "const ns_§in: Api(Author).In(.register)", None),
    ("ns_fields_on_var", C, "_ = ns_in.§;", ("_ = ns_in.email;", "_ = ns_in.§;")),
    ("ns_action_name", C, "try Api(Author).call(.§, ns_in);", ("try Api(Author).call(.register, ns_in);", "try Api(Author).call(.§, ns_in);")),
    ("ns_action_name_via_const", C, "try AuthorApi.call(.§, .{});", ('try AuthorApi.call(.rename, .{ .name = "z" });', "try AuthorApi.call(.§, .{});")),
    ("ns_literal_fields", C, "try AuthorApi.call(.rename, .{ .§ });", ('try AuthorApi.call(.rename, .{ .name = "z" });', "try AuthorApi.call(.rename, .{ .§ });")),
    ("ns_hover_result", H, "const ns_§a = try Api(Author)", None),
    ("ns_fields_on_result", C, "_ = ns_a.§;", ("_ = ns_a.email;", "_ = ns_a.§;")),
    ("ns_members", C, "const AuthorApi = Api(Author).§;", ("const AuthorApi = Api(Author);", "const AuthorApi = Api(Author).§;")),
    ("ns_sig_call", S, "try Api(Author).call(.register, §ns_in);", None),
    # --- control: user-written record struct as parameter type
    ("control_hover_param", H, "fn control(auth§or: Author)", None),
    ("control_fields_on_param", C, "return author.§;", ("return author.name;", "return author.§;")),
    ("control_def_field", D, "return author.na§me;", None),
]

GENERATED = [
    ("literal_fields_author_register", C, "Author.register(.{ .§ });",
     ('Author.register(.{ .email = "x", .name = "y" });', "Author.register(.{ .§ });")),
    ("literal_fields_post_draft", C, "Post.draft(.{ .§ });",
     ('Post.draft(.{ .author_id = 1, .title = "t", .body = null });', "Post.draft(.{ .§ });")),
    ("literal_fields_typed_decl", C, "var in: Author.RegisterInput = .{ .§ };",
     ('var in: Author.RegisterInput = .{ .email = "a@b.c", .name = "ann" };', "var in: Author.RegisterInput = .{ .§ };")),
    ("action_name_author", C, "const lit = try Author.§;",
     ('const lit = try Author.register(.{ .email = "x", .name = "y" });', "const lit = try Author.§;")),
    ("action_name_post", C, "const d = try Post.§;",
     ('const d = try Post.draft(.{ .author_id = 1, .title = "t", .body = null });', "const d = try Post.§;")),
    ("hover_input_arg_at_call", H, "Author.register(i§n);", None),
    ("hover_var_of_derived_type", H, "var i§n: Author.RegisterInput", None),
    ("hover_hook_param", H, "fn normalize(in§put: *Author.RegisterInput)", None),
    ("hover_run_result", H, "const §a = try Author.register(in);", None),
    ("hover_run_callee", H, "const a = try Author.regi§ster(in);", None),
    ("hover_derived_type_expr", H, "var in: Author.Register§Input", None),
    ("hover_field_on_derived_var", H, "_ = in.em§ail;", None),
    ("hover_post_input_var", H, "const post_§in: Post.PublishInput", None),
    ("hover_post_result", H, "const §p = try Post.publish(post_in);", None),
    ("fields_on_derived_var", C, "_ = in.§;", ("_ = in.email;", "_ = in.§;")),
    ("fields_on_run_result", C, "_ = a.§;", ("_ = a.email;", "_ = a.§;")),
    ("fields_on_post_input_var", C, "_ = post_in.§;", ("_ = p.title;", "_ = post_in.§;")),
    ("fields_on_post_result", C, "_ = p.§;", ("_ = p.title;", "_ = p.§;")),
    ("fields_on_hook_param", C, "input.§;\n}\n\n// Control", ('input.name = "Ann";\n}\n\n// Control', "input.§;\n}\n\n// Control")),
    ("def_derived_type", D, "var in: Author.Register§Input", None),
    ("typedef_derived_var", T, "_ = i§n.email;", None),
    ("def_field_of_derived", D, "_ = in.em§ail;", None),
    ("def_field_in_literal", D, 'Author.register(.{ .em§ail = "x"', None),
    ("def_action_enum_literal", D, "const a = try Author.regi§ster(in);", None),
    ("def_field_of_run_result", D, "_ = a.em§ail;", None),
    ("sig_run_third_arg", S, "const a = try Author.register(§in);", None),
    ("sig_run_empty", S, "const a = try Author.register(§);", ("const a = try Author.register(in);", "const a = try Author.register(§);")),
    ("control_hover_param", H, "fn control(auth§or: Author)", None),
    ("control_fields_on_param", C, "return author.§;", ("return author.name;", "return author.§;")),
    ("control_def_field", D, "return author.na§me;", None),
]


VARIATIONS = [
    ("v1_struct_literal_hover", H, "const v§1: V1", None),
    ("v1_struct_literal_fields", C, "_ = v1.§;", ("_ = v1.email;", "_ = v1.§;")),
    ("v1_struct_literal_init", C, "const v1: V1 = .{ .§ };", ('const v1: V1 = .{ .email = "e", .name = "n" };', "const v1: V1 = .{ .§ };")),
    ("v2_enum_literal_hover", H, "const v§2: V2", None),
    ("v2_enum_literal_members", C, "const v2: V2 = .§;", ("const v2: V2 = .register;", "const v2: V2 = .§;")),
    ("v3_generic_struct_hover", H, "const v§3: V3(Author)", None),
    ("v3_generic_struct_fields", C, "_ = v3.§;", ("_ = v3.email;", "_ = v3.§;")),
    ("v3_generic_struct_init", C, "const v3: V3(Author) = .{ .§ };", ('const v3: V3(Author) = .{ .email = "e", .record = undefined };', "const v3: V3(Author) = .{ .§ };")),
    ("v3_generic_struct_field_hover", H, "_ = v3.em§ail;", None),
    ("v4_selected_enum_arg", C, "v4(Author, .§);", ("v4(Author, .register);", "v4(Author, .§);")),
    ("v4_sig", S, "v4(Author, §.register);", None),
    ("v4b_selected_enum_var_hover", H, "const v4§b: V4Name(Author)", None),
    ("v4b_selected_enum_var_members", C, "const v4b: V4Name(Author) = .§;", ("const v4b: V4Name(Author) = .register;", "const v4b: V4Name(Author) = .§;")),
    ("v5_switch_hover", H, "const v5_§in: V5(Author, .register)", None),
    ("v5_switch_fields", C, "_ = v5_in.§;", ("_ = v5_in.email;", "_ = v5_in.§;")),
    ("v5_switch_action_arg", C, "v5(Author, .§, .{});", ('v5(Author, .register, .{ .email = "e", .name = "n" });', "v5(Author, .§, .{});")),
    ("v5_switch_literal_fields", C, "v5(Author, .register, .{ .§ });", ('v5(Author, .register, .{ .email = "e", .name = "n" });', "v5(Author, .register, .{ .§ });")),
    ("v6_ns_fn_members", C, "const v6 = V6(Author).§;", ('const v6 = V6(Author).register(.{ .email = "e", .name = "n" });', "const v6 = V6(Author).§;")),
    ("v6_ns_fn_literal_fields", C, "const v6 = V6(Author).register(.{ .§ });", ('const v6 = V6(Author).register(.{ .email = "e", .name = "n" });', "const v6 = V6(Author).register(.{ .§ });")),
    ("v6_ns_fn_sig", S, "const v6 = V6(Author).register(§.{ .email", None),
    ("v6_ns_fn_result_fields", C, "_ = v6.§;", ("_ = v6.email;", "_ = v6.§;")),
    ("v6_alias_literal_fields", C, "const v6b = AuthorV6.register(.{ .§ });", ('const v6b = AuthorV6.register(.{ .email = "e", .name = "n" });', "const v6b = AuthorV6.register(.{ .§ });")),
    ("v8_generic_struct_param_literal", C, "v8(.{ .§ });", ("v8(.{ .email = \"e\", .record = undefined });", "v8(.{ .§ });")),
    ("v8_sig", S, "v8(§.{ .email", None),
    ("v7_fieldenum_hover", H, "const v§7: V7", None),
    ("v7_fieldenum_members", C, "const v7: V7 = .§;", ("const v7: V7 = .email;", "const v7: V7 = .§;")),
]


def digest(method, result, uri_base):
    """Compact one-line-ish rendering of a response for summary.txt."""
    if result is None:
        return "null"
    if isinstance(result, dict) and "error" in result and len(result) == 1:
        return "ERROR " + json.dumps(result["error"])
    if method == C:
        items = result["items"] if isinstance(result, dict) else result
        parts = []
        for it in items[:40]:
            ld = it.get("labelDetails") or {}
            extra = it.get("detail") or ld.get("description") or ld.get("detail") or ""
            parts.append(f"{it['label']}" + (f" [{extra}]" if extra else ""))
        more = f" ... (+{len(items) - 40} more)" if len(items) > 40 else ""
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
            s["label"] + " params=" + json.dumps([p["label"] for p in s.get("parameters", [])]) for s in sigs
        )
    return json.dumps(result)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zls", required=True)
    ap.add_argument("--zig", required=True)
    ap.add_argument("--workspace", required=True)
    ap.add_argument("--out", default="results")
    ap.add_argument("--settle", type=float, default=3.0, help="seconds to wait after didOpen")
    ap.add_argument("--build-wait", type=float, default=45.0, help="seconds to wait for build-on-save diagnostics")
    args = ap.parse_args()

    ws = os.path.realpath(args.workspace)
    base = "file://" + ws + "/"
    os.makedirs(args.out, exist_ok=True)
    raw = {"zls_version": subprocess.check_output([args.zls, "--version"]).decode().strip(),
           "zig_version": subprocess.check_output([args.zig, "version"]).decode().strip(),
           "probes": {}, "diagnostics": {}, "inlay_hints": {}}
    summary = [f"ZLS {raw['zls_version']}  Zig {raw['zig_version']}", ""]

    def start(build_on_save):
        c = Client(args.zls, {"zig_exe_path": args.zig, "enable_build_on_save": build_on_save})
        init = c.request("initialize", {
            "processId": os.getpid(), "rootUri": base.rstrip("/"), "capabilities": CAPS,
            "workspaceFolders": [{"uri": base.rstrip("/"), "name": "probe"}],
        })
        c.notify("initialized", {})
        return c, init

    def open_doc(c, name):
        text = open(os.path.join(ws, name)).read()
        c.notify("textDocument/didOpen", {"textDocument": {"uri": base + name, "languageId": "zig", "version": 1, "text": text}})
        return text

    # ---- Phase 1: feature probes, build-on-save off ----
    c, init = start(False)
    raw["server_info"] = init.get("serverInfo")
    raw["server_capabilities"] = init.get("capabilities")
    for fname, probes in (("derived.zig", DERIVED), ("generated.zig", GENERATED), ("variations.zig", VARIATIONS)):
        original = open_doc(c, fname)
        time.sleep(args.settle)
        uri = base + fname
        version = 1
        summary.append(f"===== {fname} =====")
        for name, method, anchor, edit in probes:
            text = original
            if edit:
                old, new = edit
                assert original.count(old) == 1, f"edit target not unique: {old!r}"
                text = original.replace(old, new.replace(M, ""))
            version += 1
            c.notify("textDocument/didChange", {"textDocument": {"uri": uri, "version": version}, "contentChanges": [{"text": text}]})
            pos = pos_of(text, anchor)
            params = {"textDocument": {"uri": uri}, "position": pos}
            if method == C:
                params["context"] = {"triggerKind": 2, "triggerCharacter": "."} if anchor[anchor.index(M) - 1] == "." else {"triggerKind": 1}
            if method == S:
                params["context"] = {"triggerKind": 1, "isRetrigger": False}
            result = c.request(method, params)
            raw["probes"][f"{fname}:{name}"] = {"method": method, "anchor": anchor, "edited": bool(edit), "position": pos, "result": result}
            summary.append(f"[{name}] {method.split('/')[1]} @ {anchor!r}\n    -> {digest(method, result, base)}")
        # restore and ask for inlay hints over the whole file
        version += 1
        c.notify("textDocument/didChange", {"textDocument": {"uri": uri, "version": version}, "contentChanges": [{"text": original}]})
        lines = original.split("\n")
        hints = c.request("textDocument/inlayHint", {"textDocument": {"uri": uri}, "range": {"start": {"line": 0, "character": 0}, "end": {"line": len(lines), "character": 0}}})
        raw["inlay_hints"][fname] = hints
        summary.append(f"[inlay_hints] {len(hints or [])} hints")
        for h in hints or []:
            label = h["label"] if isinstance(h["label"], str) else "".join(p["value"] for p in h["label"])
            ln = h["position"]["line"]
            summary.append(f"    L{ln + 1}:{h['position']['character'] + 1} kind={h.get('kind')} {label!r}   | {lines[ln].strip()}")
        summary.append("")
    logs = lambda cl: [n for n in cl.notifications if n.get("method") in ("window/logMessage", "window/showMessage")]
    raw["phase1_log"] = logs(c)
    bad = [n["params"]["message"] for n in logs(c) if n["params"].get("type") in (1, 2)]
    summary.append("ZLS warnings/errors during feature probes: " + (json.dumps(bad) if bad else "none"))
    summary.append("")

    # ---- Phase 2: diagnostics without build-on-save ----
    summary.append("===== diagnostics, enable_build_on_save=false =====")
    for fname in ("derived_bad.zig", "generated_bad.zig"):
        open_doc(c, fname)
    time.sleep(args.settle + 3)
    for fname in ("derived.zig", "generated.zig", "derived_bad.zig", "generated_bad.zig"):
        d = c.diagnostics(base + fname)
        raw["diagnostics"][f"no_build_on_save:{fname}"] = d
        summary.append(f"{fname}: {'never published' if d is None else json.dumps(d)}")
    c.close()
    summary.append("")

    # ---- Phase 3: diagnostics with build-on-save (default config: null -> auto, and explicit true) ----
    for label, setting in (("enable_build_on_save=null (default)", None), ("enable_build_on_save=true", True)):
        summary.append(f"===== diagnostics, {label} =====")
        c, _ = start(setting)
        texts = {f: open_doc(c, f) for f in ("derived_bad.zig", "generated_bad.zig")}
        for f, t in texts.items():
            c.notify("textDocument/didSave", {"textDocument": {"uri": base + f}})
        deadline = time.time() + args.build_wait
        while time.time() < deadline:
            ds = [c.diagnostics(base + f) for f in texts]
            if all(d is not None and len(d) >= 2 for d in ds):
                break
            time.sleep(0.5)
        time.sleep(2)
        for fname in ("derived.zig", "generated.zig", "derived_bad.zig", "generated_bad.zig"):
            d = c.diagnostics(base + fname)
            raw["diagnostics"][f"{label}:{fname}"] = d
            if d is None:
                summary.append(f"{fname}: never published")
            else:
                summary.append(f"{fname}: {len(d)} diagnostics")
                for x in d:
                    s = x["range"]["start"]
                    summary.append(f"    {s['line'] + 1}:{s['character'] + 1} source={x.get('source')} code={x.get('code')} {x['message']!r}")
        raw["diagnostics"][f"{label}:log"] = logs(c)
        bad = [n["params"]["message"] for n in logs(c) if n["params"].get("type") in (1, 2)]
        summary.append("ZLS warnings/errors: " + (json.dumps(bad) if bad else "none"))
        c.close()
        summary.append("")

    # Recorded output is made machine-independent: the workspace and home directory are replaced.
    def scrub(text):
        return text.replace(base, "file:///WORKSPACE/").replace(ws, "/WORKSPACE").replace(os.path.expanduser("~"), "~")

    open(os.path.join(args.out, "raw.json"), "w").write(scrub(json.dumps(raw, indent=1)))
    open(os.path.join(args.out, "summary.txt"), "w").write(scrub("\n".join(summary) + "\n"))
    print(scrub("\n".join(summary)))


if __name__ == "__main__":
    sys.exit(main())
