# Editor support inside the `extensions` block (ZLS 0.17.0)

Research for issue #16. ADR 0004 puts an extension's options inside an `extensions` block of the `resource` declaration, keyed by extension name, and derives the block's type from the registered extension list with `@Struct`. It records that editor completion inside the block "is not expected on ZLS 0.17.0 and was not measured". This measures it, and asks the question ADR 0001 answered one level up: does writing the entry with the extension's named type, `.postgres = postgres.Options(@This()){ ... }`, restore completion of the extension's option names, and at what cost.

Measured on 2026-11-11. Statements are tagged **[measured]** (raw LSP responses from the real server, or compiler output, recorded in `zls-extensions-block/results/`), **[source]** (read from ZLS 0.17.0 source, not exercised) or **[inferred]** (a conclusion drawn from the two, not itself observed).

## Answer

1. **Extension names do not complete.** **[measured]** `.extensions = .{ .| }` returns `null` in every spelling, with or without an entry already present, with or without a typed prefix. Hover and go-to-definition on the key `.postgres` are `null` too. Hover on `.extensions` itself shows `extensions: ExtensionBlock(R) = .{}` with type `(unknown type)`.
2. **With the anonymous literal, an extension's option names do not complete.** **[measured]** `.postgres = .{ .| }` returns `null`; hover and go-to-definition on `.table` and `.attributes` are `null`.
3. **With the named type they do, and the prototype needed no change.** **[measured]** `.postgres = postgres.Options(@This()){ .| }` offers `table [[]const u8]; attributes [(unknown type) = .{}]`. Hover on `.table` shows `table: []const u8`; go-to-definition lands on the field in `postgres.zig`. `postgres.Options` is already public in the prototype because the extension contract requires it (the kernel calls `E.Options(R)`), so the spelling compiles as is, and the generated source is byte-identical to the anonymous spelling's. The gain stops at the first derived type: the keys of the extension's per-attribute block and the option names inside one of its entries still return `null`, unless that entry is in turn written with its own named type (`.email = postgres.AttributeOptions{ .| }` offers `column [?[]const u8 = null]`).
4. **Diagnostics are unaffected by the spelling, and need a `check` step.** **[measured]** With a `check` step in `build.zig` (or `enable_build_on_save` set), a misspelt extension name, option name, per-attribute key or per-attribute option produces one error about half a second after saving (on a warm cache), on exactly the misspelt identifier, with the same message and position as plain `zig build`, in both spellings. The prototype's `build.zig` as it stands has no `check` step, and with ZLS's default configuration it produces no diagnostics at all.

The cause of 1 and 2 is one thing: ZLS types the `extensions` option as unknown because it does not evaluate `@Struct`, and completion inside a nested anonymous literal works by resolving each enclosing field in turn. **[measured]** A control with the same anonymous nesting under a hand-written block type completes both the extension name and the option names.

## Versions and how they were obtained

| Tool | Version | Source |
| --- | --- | --- |
| Zig | 0.17.0 (`zig version` prints `0.17.0`) | mise, directory-scoped pin |
| ZLS | 0.17.0 (`zls --version` prints `0.17.0`; `serverInfo` = `{"name":"zls","version":"0.17.0"}`; sha256 `157cd6404052c6d419fbb0b0c1355b302a939bae09a9578cd8711ab44161dac3`, the same binary as the two previous measurements) | mise, directory-scoped pin |
| Python (driver) | 3.14.6 | system |
| Platform | macOS (Darwin 25.3.0), aarch64 | |

No global tool configuration was changed. The driver passes `--config-path` to an empty JSON file so a user config cannot leak in.

## Method

Everything is under `docs/research/zls-extensions-block/`:

- `base/`: `prototype/extension-mechanism/` from the branch of that name (`zava.zig`, `postgres.zig`, `gen.zig`, `runner.zig`, `app.zig`, `domain.zig`, `build.zig`), unchanged except `build.zig`, which gained a `with_check` switch the driver rewrites. `false` is the prototype's build exactly; `true` adds `b.step("check", ...)` depending on the app's compile step.
- `variants/`: one `domain.zig` per spelling of the entry. Each is the prototype's domain (three resources: `Author` with `table` and a per-attribute `column`, `Post` with `table` only, `Ping` with no entry) with only the entry rewritten. Every variant passes `zig fmt --check`, `zig build run` and `zig build check`, and produces the same generated `api.zig` (sha256 `d8a5ca4a1c33e936…` for all eight).

| Variant | The entry |
| --- | --- |
| a `anon` | `.postgres = .{ ... }` (ADR 0004, the prototype) |
| b `named` | `.postgres = postgres.Options(@This()){ ... }` |
| b2 `named_nested` | as b, and the per-attribute entry is `.email = postgres.AttributeOptions{ ... }` |
| c `alias` | `const Pg = postgres.Options(@This());` inside the resource struct, then `.postgres = Pg{ ... }` |
| c2 `file_alias` | `const AuthorPg = postgres.Options(Author);` at file scope, then `.postgres = AuthorPg{ ... }` |
| d `helper` | `.postgres = postgres.entry(@This(), .{ ... })`, with `pub fn entry(comptime R: type, o: Options(R)) Options(R) { return o; }` added to the extension |
| e `const` | `const Pg = postgres.Options(@This()); const pg: Pg = .{ ... };` inside the resource struct, then `.postgres = pg` |
| f `control` | a, plus a control at the end of the file: `const HandBlock = struct { postgres: ?postgres.Options(Author) = null };` under `const Hand = struct { extensions: HandBlock = .{} };`, written `Hand{ .extensions = .{ .postgres = .{ ... } } }` |

- `lsp_driver.py`: the client code (`Client`, `Session`, `pos_of`, `digest`) from the previous measurement (`docs/research/zls-generated-source-and-declarations/lsp_driver.py` on branch `research/zls-generated-source`), unchanged, with new probe lists. It starts `zls`, speaks JSON-RPC over stdio and records every response. Cursor positions come from anchor strings. Completion probes edit the open document in memory to the incomplete form; the name being completed is removed first, because ZLS omits members that are already present. Each session first polls a control completion (the top-level option names of `zava.Options(@This()){ ... }` on `Ping`) until it answers, so that no probe runs before ZLS has loaded the build's module graph; that control returned `attributes; actions; extensions` in every session.
- `alias_probe.py`: a short follow-up on spelling c (where an alias completes and where it does not), output in `results/alias-probe.txt`.
- `results/summary.txt` (digest) and `results/raw.json` (every raw response, compiler output and ZLS log line). Paths are scrubbed to `/SCRATCH`.

The diagnostics runs start ZLS on a compiling declaration, wait 12 s, write a misspelling to disk and send `didSave`, record every `publishDiagnostics`, then write the fix and send `didSave` again. Separately, the same misspelt file is built with plain `zig build` in its own copy.

To rerun:

```sh
cp -r docs/research/zls-extensions-block /tmp/zls-ext-probe && cd /tmp/zls-ext-probe
mise trust && mise install
python3 lsp_driver.py --zls "$(mise which zls)" --zig "$(mise which zig)" --src . --scratch /tmp/zls-ext-scratch --out results
```

A full run takes about 6 minutes; `--only probes` or `--only diagnostics` selects a part.

## 1. Extension names

All rows **[measured]**, identical in all eight variants.

| Probe | Result |
| --- | --- |
| `zava.Options(@This()){ .name = "ping", .primary_key = .id, .extensions = .{ .\| } }` | `null` |
| `.extensions = .{ .\|, .postgres = ... }` (an entry already present) | `null` |
| `.extensions = .{ .po\| }` (typed prefix, invoked rather than triggered by `.`) | `null` |
| Hover on `.extensions` | `extensions: ExtensionBlock(R) = .{}`, type `((unknown type))` |
| Go-to-definition on `.extensions` | `zava.zig:54:9` (the field of `Options`) |
| Hover and go-to-definition on the key `.postgres` | `null`, `null` |

The control, **[measured]**: with the hand-written block type, `Hand{ .extensions = .{ .| } }` offers `postgres [?Options(Author) = null]`, hover on `.postgres` shows `postgres: ?postgres.Options(Author) = null` and go-to-definition lands on the field.

## 2 and 3. An extension's option names, per spelling

All cells **[measured]**. "no" is the literal `null`. Completion cells quote what was offered.

| Probe | a anon | b named | b2 named, nested | c alias in struct | c2 alias at file scope | d helper | e constant |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Option names, empty entry, triggered by `.` | no | **`table [[]const u8]; attributes [(unknown type) = .{}]`** | **same** | no | **same** | **same** | **same** |
| Option names after `.table = "authors",` | no | **`attributes [(unknown type) = .{}]`** | **same** | no | **same** | **same** | **same** |
| Option names with a typed prefix, `.ta\|` | no | **`table; attributes`** | **same** | **`table; attributes`** | **same** | **same** | **same** |
| Option names, second resource, entry on one line | no | **`table; attributes`** | **same** | no | **same** | **same** | **same** |
| Keys of the extension's per-attribute block, `.attributes = .{ .\| }` | no | no | no | no | no | no | no |
| Option names inside a per-attribute entry, `.email = <entry>{ .\| }` | no | no | **`column [?[]const u8 = null]`** | no | no | no | no |
| Hover on `.table` | no | `table: []const u8` | same | same | same | no | same |
| Hover on `.attributes` | no | `attributes: zava.PerAttribute(R, AttributeOptions) = .{}`, type `((unknown type))` | same | same | same | no | same |
| Go-to-definition on `.table`, `.attributes` | no | `postgres.zig:14:9`, `postgres.zig:15:9` | same | same | same | no | same |
| Hover and go-to-definition on the per-attribute key `.email` | no | no | no | no | no | no | no |
| Hover and go-to-definition on `.column` | no | no | `column: ?[]const u8 = null`; `postgres.zig:10:39` | no | no | no | no |

Other probes, **[measured]**:

- b: hover on `Options` in `postgres.Options(@This()){` shows `fn Options(comptime R: type) type`; go-to-definition `postgres.zig:12:8`. Hover on `postgres` shows the import and the extension file's doc comment.
- b2: hover on `AttributeOptions` shows `const AttributeOptions = struct { column: ?[]const u8 = null }`.
- c and c2: hover on the alias shows `const Pg = postgres.Options(@This())` (c2: `const AuthorPg = postgres.Options(Author)`), type `(type)`; go-to-definition goes to the struct inside `postgres.Options` (`postgres.zig:13:12`).
- d: hover on `entry` shows `fn entry(comptime R: type, o: Options(R)) Options(R)` with its doc comment; signature help works (`activeParameter=1`). Every hover and go-to-definition inside the literal is `null`, as the previous measurement found for the function-argument form of the top-level declaration.
- e: hover on `pg` shows the declaration text and type `(Options(Author))`.
- The control: under the hand-written block, the anonymous `.postgres = .{ .| }` offers `table; attributes`, and hover and go-to-definition on `.table` work. Its per-attribute block is still `PerAttribute` (derived), and its keys and entry options are still `null`.
- ZLS logged no warnings or errors in any session.

### What the named type needed, and what it costs

**[measured]** Nothing had to change in the prototype for spellings b, b2, c, c2 and e. `postgres.Options` and `postgres.AttributeOptions` are `pub` there. The compiler accepts the named value where the block's field type is `?postgres.Options(R)`, and the generated `api.zig` is byte-identical across all spellings.

**[inferred]** Why that is not an accident of this prototype: ADR 0004's contract makes `pub fn Options(comptime R: type) type` a required member of every extension, and the kernel builds the block's field type by calling it. So the named type exists for every extension by construction, and the extension author pays nothing. A per-attribute options type is only nameable if the extension author chooses to make it a public declaration, which the prototype's `postgres` does.

Cost to the developer of spelling b, relative to a:

- **[measured]** 24 more characters per entry (`postgres.Options(@This())` in place of `.`), on the same line.
- **[inferred]** The file that declares the resource must import the extension. The prototype's single `domain.zig` already does, because it lists `pub const extensions = .{postgres};`. A domain split over several files, which was not prototyped, would need the import in each resource file that has an entry; the anonymous spelling would not.
- **[inferred]** `@This()` must be the resource. Writing another resource's type there is a compile error (type mismatch against `?postgres.Options(R)`), not a silent mistake. Not measured.

The alternatives are not cheaper:

- c (alias inside the struct) costs a line per resource and is worse than b: completion on the bare `.` trigger returns `null`, the first option name completes only once a letter is typed, and a second option name after a first does not complete at all (`results/alias-probe.txt`). c2 (alias at file scope) behaves like b but costs a line per resource per extension and repeats the resource's name.
- d (helper function) gives the same completion as b, loses all hover and go-to-definition inside the literal, and costs every extension author one more function (it is the only spelling that needed a change: the five-line `entry` function appended to `postgres.zig`).
- e (separate constant) behaves like b for completion and hover, and costs two lines per resource and moves the options away from the block.

## 4. Diagnostics on a misspelling

All rows **[measured]**. The misspellings are made in `Author`'s entry: extension name `.postgers`, option name `.tabel`, per-attribute key `.emial`, per-attribute option `.colum`.

### The compiler, plain `zig build`

Exit code 1 in every case. Positions are of the misspelt identifier (the token after the `.`). Line numbers in b are one higher only because that variant file's header comment is one line longer.

| Misspelling | Error (a anon) | Error (b named) | Note |
| --- | --- | --- | --- |
| Extension name | `domain.zig:19:27: error: no field named 'postgers' in struct 'zava.ExtensionBlock(domain.Author)'` | same at `20:27` | `zava.zig:45:12: note: struct declared here` |
| Option name | `domain.zig:20:14: error: no field named 'tabel' in struct 'postgres.Options(domain.Author)'` | same at `21:14` | `postgres.zig:13:12: note: struct declared here` |
| Per-attribute key | `domain.zig:21:31: error: no field named 'emial' in struct 'zava.PerAttribute(domain.Author,postgres.AttributeOptions)'` | same at `22:31` | `zava.zig:30:12: note: struct declared here` |
| Per-attribute option | `domain.zig:21:43: error: no field named 'colum' in struct 'postgres.AttributeOptions'` | same at `22:43` | `postgres.zig:10:30: note: struct declared here` |

The message and the location do not depend on the spelling. The compiler does not list the valid names or suggest the nearest one.

### The editor, on save

| Configuration | Result |
| --- | --- |
| `check` step, `enable_build_on_save` at its default; a and b; all four misspellings | **Arrives.** One diagnostic on `domain.zig`, severity 1, source `zls`, range exactly the misspelt identifier (for example `19:27-19:35` for `postgers`), message identical to the compiler's, with the `struct declared here` note as related information. It is published 0.45 to 0.56 s after the save (12 runs; the save is first answered within 0.1 s by an empty publish). After the fix is saved the diagnostic is withdrawn 0.17 to 0.24 s later and stays withdrawn (checked 6 s on). ZLS logs `Build-On-Save is running for "/SCRATCH/diag/"` |
| No `check` step, `enable_build_on_save` at its default (the prototype's `build.zig` and a default ZLS); a; option name | **Nothing.** No diagnostics within 30 s. ZLS does not log that build-on-save is running |
| No `check` step, `enable_build_on_save = true`; a and b; extension name and option name | **Arrives**, same diagnostics and positions as the first row. ZLS runs the install step, which in the prototype compiles the generator and so the declaration |

So the misspelling diagnostics are the compiler's, relayed, and are the same in both spellings. What decides whether they arrive is the build script, not the declaration: the real build helper has to declare a `check` step (the opt-in ZLS documents for build-on-save), because without it a developer with a default ZLS gets neither completion in the block nor an error on save.

## Causes

**[source]** ZLS's struct-literal completion walks tokens backwards from the `.` to find something that names the literal's type ([completions.zig, `getSwitchOrStructInitContext`, L1245-L1457](https://github.com/zigtools/zls/blob/0.17.0/src/features/completions.zig#L1245-L1457)):

- For `.name = .{ .|` it stops at the identifier before the `=` ([L1324-L1331](https://github.com/zigtools/zls/blob/0.17.0/src/features/completions.zig#L1324-L1331)). That identifier is itself a field name in an enclosing literal, so `collectEnumLiteralContainerNodes` runs the same search again from that field's `.`, resolves the enclosing literal's type, looks the field up in it and takes the field's type, unwrapping an optional ([L1837-L1857](https://github.com/zigtools/zls/blob/0.17.0/src/features/completions.zig#L1837-L1857)). So nested anonymous literals complete by walking outwards one field at a time until a named type is reached, and every field on the way must have a type ZLS can resolve.
- For `f(args){ .|` it takes the function name before the parentheses and asks for the function's return type ([L1374-L1406](https://github.com/zigtools/zls/blob/0.17.0/src/features/completions.zig#L1374-L1406), [L1768-L1792](https://github.com/zigtools/zls/blob/0.17.0/src/features/completions.zig#L1768-L1792)). For `S{ .|` it takes the identifier ([L1281-L1283](https://github.com/zigtools/zls/blob/0.17.0/src/features/completions.zig#L1281-L1283)). Neither looks further out.

**[source]** ZLS resolves a builtin call's type through a switch over the builtins it implements (`@This`, `@as`, `@TypeOf`, `@import`, `@FieldType`, `@field`, `@Vector` and a few more). Anything else, `@Struct` included, falls to a branch that only reports the builtin's declared return type, with no value ([analysis.zig L2305-L2472](https://github.com/zigtools/zls/blob/0.17.0/src/analysis.zig#L2305-L2472)).

**[inferred]** Together with the measurements:

- Extension names: the search from `.extensions = .{ .|` reaches `zava.Options(@This()){`, resolves that struct (the control completion proves it does) and finds the field `extensions`, whose type is the result of `@Struct`: unknown. There is nothing to list. No spelling of the entry can change this, because the entry is inside the block, not around it.
- Anonymous entry: the search from `.postgres = .{ .|` must first resolve `.postgres` in the block's type, which is unknown, so it fails one step earlier than its own level. The control (same nesting, hand-written block) completing both levels is the measurement that separates this cause from a syntactic one.
- Named entry: the type is named at the literal, so the search never has to pass through the block. That is why it works and also why it only helps its own level: the per-attribute block inside it is again a `@Struct` result (`PerAttribute`), and naming `postgres.AttributeOptions` at the innermost literal (b2) skips over it in the same way.
- Diagnostics do not involve any of this. They are compiler output relayed by build-on-save, so they are as exact as the compiler's in every spelling.

Not traced in source: why the alias inside the struct (c) returns `null` on a bare `.`. **[measured]** (`results/alias-probe.txt`) The pattern is that c fails exactly when the buffer does not parse (`Pg{ . }`, `Pg{ .table = "posts", . }`, `Pg{ .table = "posts", .a }`) and works when it does (`Pg{ .t }`, where `.t` parses as an enum literal). An alias of the same generic call at file scope or inside a function body, and a file-scope alias of a plain struct, all complete on the bare `.`. **[inferred]** ZLS does not find a declaration of the enclosing struct by name while a member of that struct fails to parse; spelling e, which also declares `Pg` inside the struct, is not affected because there the alias is a type annotation, which ZLS resolves from the syntax tree rather than by name lookup ([L1674-L1691](https://github.com/zigtools/zls/blob/0.17.0/src/features/completions.zig#L1674-L1691)). Also not traced: why the function-argument form (d) has no hover inside the literal.

## Not verified

- Behaviour inside an actual editor. Only raw LSP was recorded. In particular, whether an editor re-requests completion after a letter is typed following a `.` that returned `null` (which is what would make spelling c usable) was not tested.
- More than one registered extension. The prototype registers one. With two, the block has two fields; nothing measured here depends on the count, but it was not run.
- An extension whose `Options(R)` is itself built with `@Struct` or returns a derived type rather than a source-written `struct { ... }`. The named spelling works because ZLS can resolve the return type of `postgres.Options`; for such an extension it would not. Not measured.
- A domain split over several files, and an extension reached as a package dependency (`build.zig.zon`) rather than a module of the same build. The import cost of the named spelling is inferred, and the previous report quotes ZLS 0.17.0's release notes as listing regressions for modules reached through dependencies.
- Wrong-resource mistakes in the named spelling (`postgres.Options(Post)` inside `Author`): expected to be a type-mismatch compile error; not run.
- Diagnostics were measured for spellings a and b only, and for misspelt names only: not for a missing required option (`table`), a wrong value type, or the extension's own `@compileError` validations (ADR 0004's column-collision and type-mapping errors).
- The 12 s wait before the misspelling is saved lets ZLS's first build finish, so the half-second figure is for a warm cache; diagnostics timing on a cold cache, on a realistic domain, and with a `check` step that does more than compile the app were not measured. Timings are from one machine.
- Rename, references and semantic tokens inside the block were not probed.
- Only macOS aarch64. The previous report quotes the ZLS 0.17.0 release notes as saying file watching in the build server is broken on Windows, which would affect build-on-save there; not re-read here.
- Whether a later ZLS evaluates `@Struct`. `master` was not built or read for this.
- The ZLS issue tracker was not searched for this question.

## Sources

- ZLS 0.17.0 source: [src/features/completions.zig](https://github.com/zigtools/zls/blob/0.17.0/src/features/completions.zig#L1245-L1457) (`getSwitchOrStructInitContext`, `collectContainerNodes`, `collectFieldAccessTypes`, `collectEnumLiteralContainerNodes`), [src/analysis.zig](https://github.com/zigtools/zls/blob/0.17.0/src/analysis.zig#L2305-L2472) (builtin call resolution)
- The declaration and the extension: `prototype/extension-mechanism/` on branch `prototype/extension-mechanism`; ADR 0004 and ADR 0001 on `main`
- Previous measurements: `docs/research/zls-generated-source-and-declarations.md` on branch `research/zls-generated-source` (driver, form of the literal, build-on-save), `docs/research/zls-comptime-derived-types.md` on branch `research/zls-derived-types` (`@Struct` unresolved)
- Measurements: `docs/research/zls-extensions-block/results/summary.txt` and `raw.json`
