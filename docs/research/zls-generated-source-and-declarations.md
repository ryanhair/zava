# Editor support for generated source and declarations (ZLS 0.17.0)

Research for issue #12. ADR 0003 puts developer-facing types in plain Zig source that a build step generates into the build cache, and keeps behaviour in comptime code typed on those types. That rests on three editor facts nobody had measured: whether a language server resolves a module whose root is a build-step output, what it offers while a developer writes a `resource` declaration, and what it offers an extension author inside the comptime code.

Measured on 2026-11-11. Statements are tagged **[measured]** (raw LSP responses from the real server, recorded in `zls-generated-source-and-declarations/results/`), **[source]** (read from ZLS source, not exercised) or **[docs]** (documentation, release notes, issue tracker).

## Answer

1. **Generated source in the build cache is usable, and is not fresh.** **[measured]** ZLS resolves `@import("api")` to the generated file under `.zig-cache/o/<hash>/api.zig` with no prior `zig build`: it runs the generator itself when it loads `build.zig` (about 5 s on an empty cache, 0.4 s on a warm one). Completion, hover with the generated doc comments, signature help, inlay hints and go-to-definition all work from `app.zig`. But after the declaration changes, the editor keeps showing the old generated source in every configuration tried: with or without a `check` step, build-on-save on or off, after a manual `zig build`, and for `captureStdOut`, `addOutputFileArg` and `WriteFiles` alike. The only things that refreshed it were saving `build.zig` (0.3 s) or restarting ZLS. Build-on-save does regenerate the file about 2 s after the save; ZLS just keeps reading the previous cache path.
2. **The prototype's two module graphs confuse ZLS.** **[measured]** In `domain.zig` and `zava.zig`, `@import("api")` resolves to the empty stub, so hooks typed on generated types are `(unknown)`. Dropping the stub (the generator's graph simply has no `api` import; it still compiles) fixes it completely. So does ordering the build so the real graph is met first.
3. **While declaring, a developer gets almost nothing in the ADR 0001 shape.** **[measured]** `pub const resource: zava.Options(@This()) = .{ ... }` completes no option names, no attribute names, no keys or values of the per-attribute block and no declaration names. Hover shows option documentation but the attribute types are `(unknown type)`. Two independent causes: ZLS cannot see enums derived from the struct's fields, and its literal completion does not handle a type annotation that is a generic call, nor literals nested inside an array literal. A different shape recovers nearly everything: the developer writes the attribute and hook enums next to the struct, passes them in, annotates through a local alias, and declares actions and attribute entries as separate constants. Only members of an `accept` list still do not complete.
4. **An extension author gets nothing on the generated types inside generic comptime code.** **[measured]** A parameter typed `Generated(R, name)` hovers as `(unknown type)` with no completion, and loop captures over the model are unknown. The same function written against a concrete generated type gets everything. Source-written kernel types (`Shape`, the option names of `Action(R)`) do complete.

## Versions and how they were obtained

| Tool | Version | Source |
| --- | --- | --- |
| Zig | 0.17.0 | mise, directory-scoped pin |
| ZLS | 0.17.0 (`zls --version` prints `0.17.0`; `serverInfo` = `{"name":"zls","version":"0.17.0"}`; sha256 `157cd6404052c6d419fbb0b0c1355b302a939bae09a9578cd8711ab44161dac3`, the same binary as the previous measurement) | mise, directory-scoped pin |
| Python (driver) | 3.14.6 | system |
| Platform | macOS (Darwin 25.3.0), aarch64 | |

No global tool configuration was changed. `zls env` reports no user config file (`"config_file": null`); the driver also passes `--config-path` to an empty JSON file so a user config cannot leak in.

## Method

Everything is under `docs/research/zls-generated-source-and-declarations/`:

- `q1/`: the adopted split from `prototype/comptime-generation-boundary/3-types-source-behaviour-comptime`, with a second resource (`Post`, two actions, a hook) and a `Record` alias in the generated source. `build.zig` has three switches the driver rewrites:
  - `mode`: how the generated file reaches the module. `capture` (`captureStdOut`, the prototype), `outarg` (`addOutputFileArg`), `writefiles` (captured output copied through a `WriteFiles` step), `source_tree` (copied to `generated/api.zig` in the source tree with `UpdateSourceFiles`; the module root is that static path).
  - `with_check`: whether a `check` step compiles the app against the generated module.
  - `graph`: `stub` (the prototype: the generator's copy of `domain`/`zava` imports an empty stub as `api`), `no_stub` (that copy has no `api` import), `real_first` (stub kept; the app is installed first and imports `domain` and `zava` directly).
  Every `mode` (with `graph = stub`) and every `graph` (with `mode = capture`) builds and runs on Zig 0.17.0 from an empty cache.
- `q1/zava.zig` also holds the question 3 comparison: `run` (generic, typed `Generated(R, ...)`), `runRegisterConcrete` (concrete generated types), `emailMixed` (`Generated` called with concrete arguments) and `nameAliased` (a concrete alias).
- `q2/`: one `zava.zig` with four ways of typing a declaration, and one domain file per variant, each with two resources and all compiling (`zig test`). `extras.zig` holds smaller probes.
- `lsp_driver.py`: starts `zls`, speaks JSON-RPC over stdio, records every response. It reuses the client from the previous measurement, including its fix: ZLS asks `workspace/configuration` for one item with section `zls`, and the reply must be an array holding one config object per item. Cursor positions come from anchor strings; completion probes edit the open document in memory to the incomplete form. For completion of names, the name being completed is removed first, because ZLS omits members that are already present.
- `results/summary.txt` (digest) and `results/raw.json` (every raw response and ZLS log line). Paths are scrubbed to `/SCRATCH`.

The driver plays the part of an editor in two ways that matter for freshness. It accepts ZLS's dynamic registration of `workspace/didChangeWatchedFiles` (ZLS registers the glob `**/*.{zig,zon}`), and in the freshness runs it sends the events an editor's file watcher would send, as a separate step so that their effect can be told apart. Each freshness run does the following and stops at the first step after which completion of `api.Author.rename(a, .{ .| })` shows the new field:

1. change `domain.zig` in the buffer only;
2. write it to disk and send `didSave`, then wait (up to 25 s for a regenerated file to appear on disk, then 5 s for completion);
3. send `didChangeWatchedFiles` for every `*.zig` that is new or changed under the workspace, including files under `.zig-cache`;
4. run `zig build` by hand, then send watcher events again;
5. send `didSave` for `build.zig` (content unchanged);
6. restart ZLS.

To rerun:

```sh
cp -r docs/research/zls-generated-source-and-declarations /tmp/zls-gen-probe && cd /tmp/zls-gen-probe
mise trust && mise install
python3 lsp_driver.py --zls "$(mise which zls)" --zig "$(mise which zig)" --src . --scratch /tmp/zls-gen-scratch --out results
```

A full run takes about 14 minutes; `--only features,broken,fresh,q2` and `--configs name,name` select parts.

## Question 1: the generated module in the build cache

### Resolution from `app.zig`

All rows **[measured]**, configuration `capture`, `check` step present, build-on-save at its default, empty cache, ZLS started with no prior build. Both resources behaved the same in every row.

| Capability | Result | Evidence |
| --- | --- | --- |
| `@import("api")` resolves | **Works** | hover on `api`: `(type)` with the file doc comment `GENERATED. Do not edit.`; go-to-definition on the import string: `.zig-cache/o/ee46…c62a/api.zig:1:1` |
| Completion `api.\|` | **Works** | `Author [type]; Post [type]` |
| Completion `api.Author.\|` | **Works** | `Record [type]; RegisterInput [type]; register [fn (base: Author, input: RegisterInput) Author]; RenameInput [type]; rename [...]` |
| Completion in the input literal, `api.Author.register(blank, .{ .\| })` | **Works** | `email [[]const u8]; name [[]const u8]`; `api.Post.draft(empty, .{ .\| })` gives `author_id [i64]; title [[]const u8]; body [?[]const u8]` |
| Completion on a typed declaration, `var in: api.Author.RegisterInput = .{ .\| }` | **Works** | `email`, `name` |
| Completion on the record through the generated alias, `const blank: api.Author.Record = .{ .\| }` and `a.\|` | **Works** | `id [i64]; email [[]const u8]; name [[]const u8]` (plus the hook `welcome`, see below) |
| Hover on the function | **Works**, generated doc comments shown | `fn register(base: domain.Author, input: RegisterInput) domain.Author`, links to `Author` (`domain.zig`) and `RegisterInput` (cache path), then ``Runs the `register` action on `Author`.`` and ``SQL: `update authors set email = $1, name = $2` `` |
| Hover on the input type | **Works** | the struct body with its fields and ``Input of the `register` action on `Author`.`` |
| Signature help | **Works** | `fn register(base: Author, input: RegisterInput) Author`, `activeParameter=1`, documentation carries the same doc comment including the SQL line |
| Go-to-definition on the function, the input type, a field in the literal | **Works**, opens the cache path | `.zig-cache/o/ee46…c62a/api.zig:16:12`, `:9:31`, `:10:9` (workspace-relative; the directory name is a hash) |
| Go-to-definition on a field of the returned record | **Works** | `domain.zig:9:5` (the developer's struct) |
| Inlay hints | **Works** | 33 hints: `: Author` on results, `base:` / `input:` parameter names, and a type on every field of every input literal |
| Hook signature as seen from `app.zig` (`a.\|` lists `welcome`) | **Partial** in the prototype's wiring | `welcome [fn (self: *Author, input: (unknown type)) void]`; with `graph = no_stub` it is `fn (self: *Author, input: RegisterInput) void` |

### Does it need a prior build?

All rows **[measured]**. Time is from `didOpen(app.zig)` until `api.Author.` first completes, polled every 0.25 s.

| Configuration | Result |
| --- | --- |
| `capture`, check step, build-on-save default, **empty cache** | resolves after **5.16 s**; one `api.zig` now exists in `.zig-cache/o/` |
| `capture`, **no check step, build-on-save off**, empty cache | resolves after **4.77 s**. Neither a `check` step nor build-on-save is needed: loading `build.zig` runs the generator |
| `capture`, check step, cache warmed by a manual `zig build` (4.4 s) | resolves after **0.42 s** |
| `outarg`, empty cache | 4.81 s |
| `writefiles`, empty cache | 4.79 s |
| `source_tree`, check step, build-on-save default, empty cache | 4.54 s (build-on-save's first cycle wrote `generated/api.zig`) |
| `source_tree`, **no check step, build-on-save off**, empty cache | **never** (waited 90 s). Nothing generates the file: ZLS only runs steps that own a module's root source file, and here the root is a plain path |
| `capture`, empty cache, **declaration does not compile** when the editor starts | `api` **never resolves** (waited 40 s); there is no generated file. The compiler error does reach the editor on the exact token: `domain.zig 16:43 enum 'meta.FieldEnum(domain.Author)' has no member named 'nmae'`. After fixing and saving, `api` still does not resolve (30 s), nor after watcher events; it resolves 0.35 s after `build.zig` is saved |

**[source]** This matches how ZLS 0.17.0 loads a project. It starts `zig build --listen=-`, reads the serialized build configuration, collects every module reachable from a compile step, and asks the build server to run the steps that own a generated root source file, once, with `watch = false` ([bsp.zig L458-L471](https://github.com/zigtools/zls/blob/0.17.0/src/bsp.zig#L458-L471)). The result is a map from module root path to import table.

### Freshness

The edit adds `.email` to the `accept` list of `rename` in `domain.zig`. "Fresh" means completion of `api.Author.rename(a, .{ .| })` in `app.zig` lists `email`. All rows **[measured]**.

| Configuration | After save (steps 1 to 3) | Manual `zig build` (step 4) | Save `build.zig` (step 5) |
| --- | --- | --- | --- |
| `capture`, no check step, build-on-save off | stale; nothing regenerates | stale (build took 2.0 s and wrote a fresh file) | **fresh after 0.33 s** |
| `capture`, no check step, build-on-save default (so off: ZLS did not log that it was running) | stale; nothing regenerates | stale | **fresh after 0.34 s** |
| `capture`, no check step, build-on-save `true` (runs the install step) | stale, although a fresh file was on disk 2.08 s after the save | stale | **fresh after 0.35 s** |
| `capture`, check step, build-on-save off | stale; nothing regenerates | stale | **fresh after 0.33 s** |
| `capture`, check step, build-on-save default (on) | stale, although a fresh file was on disk 2.08 s after the save | stale | **fresh after 0.31 s** |
| `outarg`, check step, build-on-save on | stale; fresh file on disk after 2.08 s | stale | **fresh after 0.35 s** |
| `writefiles`, check step, build-on-save on | stale; fresh file on disk after 2.08 s | stale | **fresh after 0.33 s** |
| `source_tree`, check step, build-on-save on | stale after save and after a `Changed` watcher event, although `generated/api.zig` was rewritten 2.07 s after the save. **Fresh 0.08 s after** the watcher reports the file as `Deleted` then `Created` | not reached | not reached |

Notes on the table:

- In the first run of this measurement (`results/summary-first-run.txt`) the order of steps 4 and 5 was the other way round, so saving `build.zig` came before any build had regenerated the file. It then took **2.2 to 2.4 s** with build-on-save off (ZLS had to run the generator) and 0.3 s with it on. That run did not yet send the `Deleted`/`Created` events, and showed `source_tree` staying stale through a `build.zig` save and a manual build, becoming fresh only on restart (0.41 s). Its last two configurations are not meaningful: in them nothing ever wrote `generated/api.zig`, so `api` never resolved.
- An unsaved edit never changes anything (step 1): generation reads files on disk.
- After each stale step the stale answer was complete and self-consistent: completion, hover and go-to-definition all pointed at the previous cache directory, which still exists. Nothing tells the developer it is out of date.
- When it does become fresh, go-to-definition moves to the new cache directory and hover shows the new SQL line (``update authors set name = $1, email = $2``).

**[source]** Why. Each change of generator output lands in a new `.zig-cache/o/<hash>/` directory, so the path changes. ZLS's module map is rebuilt only when `build.zig` is saved (or the Zig path changes): the `didSave` handler invalidates the build file only if the saved document is a build file ([Server.zig L1165-L1167](https://github.com/zigtools/zls/blob/0.17.0/src/Server.zig#L1165-L1167)). Build-on-save is a separate long-running `zig build --listen=-` whose loop only pushes error bundles into diagnostics; it receives which files were generated and ignores them ([bsp.zig, `BuildOnSave.loopCatchReportError`](https://github.com/zigtools/zls/blob/0.17.0/src/bsp.zig#L1103-L1190)). So nothing connects "the check step produced a new file" to "the module map changed". On `master` at `066658e` (2026-11-08) this is unchanged: the same code, the same comments.

**[source] + [docs]** Why the stable path did not help on 0.17.0 either. ZLS 0.17.0 ignores `didChangeWatchedFiles` with type `Changed` for a file that is not open in the editor: `refreshDocumentFromFileSystem` returns early for every `file:` URI ([DocumentStore.zig L895](https://github.com/zigtools/zls/blob/0.17.0/src/DocumentStore.zig#L895)). This is a reported and fixed bug, [zigtools/zls#3305](https://github.com/zigtools/zls/issues/3305) ("ZLS ignores `didChangeWatchedFiles(Changed)` for files that are not open ... A `Deleted` event for the same file does make ZLS re-read it"), fixed four days after the release by commit [4c6b1c3](https://github.com/zigtools/zls/commit/4c6b1c33cdc1911ed0cc61e1480cd96bf23a9f3e). The measured `Deleted` then `Created` result agrees with the report.

**Exact configuration for fresh generated source in ZLS 0.17.0:** none that is automatic. In the cache, the developer must save `build.zig` or restart the language server after changing a declaration. With a stable path outside the hashed cache directories, a `check` step that depends on the generated file, build-on-save on, and an editor that delivers watched-file events, the content is refreshed about 2 s after saving once ZLS honours `Changed` events (fixed on `master`, not in 0.17.0; not measured here) or today if the file is seen as deleted and recreated.

### Does the delivery mechanism matter?

**[measured]** No, among the three that keep the file in the cache. `captureStdOut`, `addOutputFileArg` and a `WriteFiles` copy resolve the same way, take the same time, and are stale in the same way, because all three produce a path containing a content hash. The only variant that behaves differently is a static path (`source_tree`), which trades the stale path for two other problems: nothing resolves until some build has written the file, and 0.17.0 does not re-read it.

### Two module graphs

All rows **[measured]**, in `domain.zig` and `zava.zig`, with the generated module resolving fine from `app.zig` in the same session.

| Probe | `graph = stub` (prototype) | `graph = no_stub` | `graph = real_first` |
| --- | --- | --- | --- |
| Go-to-definition on `@import("api")` in `domain.zig` | `stub_api.zig:1:1` | `.zig-cache/o/…/api.zig:1:1` | `.zig-cache/o/…/api.zig:1:1` |
| `api.\|` in `domain.zig` and in `zava.zig` | `null` | `Author [type]; Post [type]` | same |
| Hover on the hook parameter `input: api.Author.RegisterInput` | `(unknown)` | `(RegisterInput)` with link | same |
| `input.\|` inside the hook (both resources) | `null` | `email`, `name` / `author_id`, `title`, `body` | same |
| Completion in `api.Author.rename(self.*, .{ .\| })` inside the hook, and signature help | `null` | `name [[]const u8]`; full signature with doc comment | same |
| Go-to-definition on `api.Author.RegisterInput` in the hook signature | `null` | `.zig-cache/o/…/api.zig:9:31` | same |

**[source]** ZLS keys modules by root source file and merges all modules that share one: "All modules with the same root source file are merged. This limitation may be lifted in the future." For a name imported by both, the first module visited wins: "This does not account for the possibility of collisions (i.e. modules with same root source file import different modules under the same name)." ([bsp.zig L598-L617](https://github.com/zigtools/zls/blob/0.17.0/src/bsp.zig#L598-L617)). Modules are visited breadth-first from the compile steps, those under the install step first. In the prototype the install step reaches only the generator (through the installed `api.zig`), so the generator's `domain` and `zava`, which import the stub, are visited first.

`no_stub` works for the build because nothing the generator analyses reaches `@import("api")`: the declaration names hooks by declaration name, and `zava.Generated` is only evaluated in the app build. `zig build run`, `zig build` and `zig build check` all pass with the `api` import simply absent from the generator's graph. It is the more robust of the two fixes, since it leaves only one module that defines `api` for those files; `real_first` depends on step order.

## Question 2: completion while writing a declaration

Variants, all in `q2/`. Each is two resources and compiles.

| Variant | Typing | Form of the literal |
| --- | --- | --- |
| A | ADR 0001 as prototyped: `std.meta.FieldEnum(T)` for attribute names, a comptime-built struct keyed by field name for per-attribute options, `std.meta.DeclEnum(T)` for the hook | `pub const resource: zava.Options(@This()) = .{` |
| A2, A3, A4 | as A | function argument `zava.resource(@This(), .{`; named type `zava.Options(@This()){`; local alias `const Options = zava.Options(@This()); pub const resource: Options = .{` |
| B | developer writes `pub const Field = enum { id, email, name };` in the struct; `OptionsDecl(T)` reads it as `T.Field` | annotation with generic call |
| C | developer writes `Field` and passes it: `zava.OptionsF(@This(), Field)`; keyed attributes block (`std.enums.EnumFieldStruct`), hook still `DeclEnum(T)` | annotation with generic call |
| D | developer writes `Field` and `Hook` enums and passes both; per-attribute options are a list of entries `.{ .field = .email, ... }` instead of a keyed block. No derived type left | annotation with generic call |
| D2, D3, D4 | as D | function argument; named type; local alias |
| E | as D | flattened: local aliases, and each action and attribute entry is its own constant (`const rename: Action = .{ ... };`); `resource` lists them by name |

In B, C, D and E a comptime check in `zava` compares the developer's enum with the struct's fields, so a mismatch is still a compiler error.

### Completion

All cells **[measured]**. "yes" quotes what was offered; "no" is the literal `null`. Positions inside an action or an attribute entry are inside an array literal (`.actions = &.{ .{ ... } }`) in every variant except E.

| Position | A | A2 / A3 / A4 | B | C | D | D2 / D3 | D4 | E |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Option names (`.table`, ...) | no | **yes** `table` | no | no | no | **yes** | **yes** | **yes** |
| `.primary_key = .\|` | no | no | no | no | no | no | **yes** `id; email; name` | **yes** |
| Option names inside an action | no | no | no | no | no | no | no | **yes** `kind; accept; after` |
| `.kind = .\|` inside an action (a source-written enum) | no | no | no | no | no | no | no | **yes** `create; read; update` |
| Member of `.accept = &.{ .\| }` | no | no | no | no | no | no | no | no (also no with `&[_]Field{ .\| }`) |
| `.after = .\|` (declaration name) | no | no | no | no | no | no | no | **yes** `welcome` (Post: `stamp`) |
| Keys of the keyed attributes block | no | no | no | no | n/a | n/a | n/a | n/a |
| Option names inside a keyed entry, `.email = .{ .\| }` | no | no | no | no | n/a | n/a | n/a | n/a |
| `.field = .\|` in a list entry | n/a | n/a | n/a | n/a | no | no | no | **yes** `id; email; name` |
| Option names in a list entry | n/a | n/a | n/a | n/a | no | no | no | **yes** `unique; column` |

The second resource (`Post`) gave the same pattern, with its own names (`id; author_id; title; body; published`).

In every variant, typing a bare identifier (`.after = wel|`) offers everything in scope, about 90 items, with `welcome` among them. That is scope completion, not typed completion.

### Hover and go-to-definition on a finished declaration

All cells **[measured]**.

| Token | A | C | D and E |
| --- | --- | --- | --- |
| `resource` | declaration text, type `(Options(Author))` | `(OptionsF(Author,Field))` | `(OptionsList(Author,Field,Hook))` |
| Option name `.table` | `table: []const u8` and its doc comment | same | same |
| Option name `.primary_key` | doc comment, type `((unknown type))` | doc comment, type `(Field)` with link | same as C |
| Value `.id` in `.primary_key = .id` | `null` | `id` `(Field)`; go-to-definition lands on the member of the developer's `Field` enum, not on the struct field | same as C |
| Member `.email` in `accept` | `null` | `email` `(Field)`; definition in the `Field` enum | same as C |
| `.after` option and its value `.welcome` | option: `(?(unknown type))`; value: `null` | same as A | option: `(?Hook)`; value: `welcome` `(Hook)`; definition in the `Hook` enum, not on the function |
| Key `.email` of the keyed attributes block, and `.unique` inside it | `null`, `null` | `null`, `null` | n/a |
| `.field = .email` and `.unique` in a list entry | n/a | n/a | `email` `(Field)`; `unique: bool = false` with its doc comment; definitions resolve |

B is like A for attribute names: `primary_key: T.Field` hovers as `(unknown)`.

The form of the literal matters for hover too. With the annotation, the named type or the alias (A, A3, A4, D, D3, D4) the rows above hold. With the function-argument form (A2, D2) every hover and go-to-definition inside the literal is `null`, including option names such as `.table`.

### Which variations helped

| Variation | Helped? | Evidence |
| --- | --- | --- |
| `Options` as a generic function returning a source-written struct (this is A) | **Only for hover on option names.** | Option documentation shows; completion of option names is `null` because of the annotation form, below |
| Any form other than annotating with the generic call: function argument, named type, or local alias | **Yes, for completion of top-level option names.** The function-argument form pays for it with hover. | A: `null`. A2, A3, A4: `table [[]const u8]`. A2 and D2 lose all hover and go-to-definition inside the literal; A3, A4, D3, D4 keep them |
| Attribute names as a source-written enum reached through the struct, `T.Field` (B) | **No.** | hover `primary_key: T.Field` is `(unknown)`; all completions `null`. ZLS does not follow a declaration looked up through a generic parameter (the previous measurement's V4) |
| Attribute names as a source-written enum passed as a parameter (C, D) | **Yes for hover and go-to-definition; for completion only together with the alias form.** | C, D: hover `(Field)`, definition resolves, completion `null`. D4: `.primary_key = .\|` gives `id; email; name`. D2 and D3 do not, although their option names complete |
| Per-attribute options as a list of entries naming their field, instead of a keyed block (D) | **Yes for hover and go-to-definition** on entries; completion only when flattened (E). | A keyed block is a comptime-built struct in every typing, so it is `(unknown type)` and nothing in it resolves |
| Hook as a developer-written enum (D) | **Yes for hover; completion when flattened.** | `(Hook)`; E: `.after = .\|` gives `welcome` |
| Flattening so no literal sits inside an array literal (E) | **Yes.** This is what makes nested positions complete. | action option names, `.kind`, `.after`, entry option names and `.field` all complete in E and in no other variant |
| `@FieldType`-based typing | **No.** | ZLS evaluates `@FieldType(Author, "email")` on a concrete type (hover `(type = []const u8)`; a field typed that way hovers `(i64)`), but offers no field names inside the string argument of `@FieldType`, `@field` or `@hasField` (`null`), and go-to-definition on the string is `null`. It gives the type of one named field; it cannot enumerate fields |
| Hook by function value instead of by name (`.after = Author.welcome`) | Completes (`Author.\|` gives `welcome [fn (self: *Author) void]`), but ADR 0003 rules it out for the build. Not a candidate | |
| Decl literals on a source-written wrapper (`const e4: AuthorField = .\|`) | **Partly.** | offers `id [AuthorField]; email [AuthorField]` and also the wrapper's own field `name`; the developer writes one declaration per attribute |
| A developer-written `union(enum)` mirroring the struct | **No** through `std.meta.FieldEnum` (`null`, although std returns the union's tag type there); **yes** through `std.meta.Tag` (`id; email; name`) | costs a second copy of every field with its type |

**[source]** Two limits in ZLS's literal completion explain the form results. It works by scanning tokens backwards from the cursor ([completions.zig, `getSwitchOrStructInitContext`](https://github.com/zigtools/zls/blob/0.17.0/src/features/completions.zig#L1245-L1457)). For `= .{ .|` it requires the token before `=` to be an identifier (`const s: S = .{.`), so an annotation ending in `)` gives up ([L1324-L1331](https://github.com/zigtools/zls/blob/0.17.0/src/features/completions.zig#L1324-L1331)). And when the enclosing `.{` is itself directly inside another brace, as for an element of an array literal, it returns nothing ([L1345-L1351](https://github.com/zigtools/zls/blob/0.17.0/src/features/completions.zig#L1345-L1351)). **[docs]** Related open reports: [#3196](https://github.com/zigtools/zls/issues/3196) (no field completion in `.init(.{ ... })`), [#1549](https://github.com/zigtools/zls/issues/1549) and [#1525](https://github.com/zigtools/zls/issues/1525) (struct-init completion inside nested structs; a maintainer calls the latter a "Known (parser) limitation"), [#3205](https://github.com/zigtools/zls/issues/3205) (completion loses generic call bindings).

### What a developer gets

In the ADR 0001 shape as written: documentation on hover for option names, and compiler errors on the exact token through build-on-save. No completion of anything, and no types for attribute names, per-attribute keys or hook names.

The best variation found is E. It costs the developer two enums per resource that repeat names already present (`Field`, `Hook`), a few alias lines, and a flatter layout. It buys completion and hover everywhere except members of `accept`. A half step, D4 (enums passed in, alias annotation, nested literals kept), buys top-level option names and `.primary_key`, plus hover and go-to-definition everywhere, for the price of the two enums and one alias line.

## Question 3: the extension author's view

All rows **[measured]** in `q1/zava.zig`, with `graph = no_stub` so that `api` resolves there. With the prototype's `stub` graph the right-hand column is also `(unknown)` / `null`, because `api` is the stub.

| Probe | Generic comptime code (`run`, parameter `input: Generated(R, inputShape(R, action).name)`) | Concrete (`runRegisterConcrete(base: domain.Author, input: api.Author.RegisterInput)`) |
| --- | --- | --- |
| Hover on `input` | `((unknown type))` | `(RegisterInput)` with link to the generated file |
| `input.\|` | `null` | `email [[]const u8]; name [[]const u8]` |
| Hover and go-to-definition on a field of `input` | not available (nothing to point at) | `email: []const u8`; `.zig-cache/o/…/api.zig:10:9` |
| Go-to-definition on the parameter's type | `Generated` goes to `pub fn Generated` (`zava.zig:36:8`); `inputShape` to its definition. Neither leads to a generated type | `.zig-cache/o/…/api.zig:9:31` |
| Hover on `base` / `r` (typed `R` or `domain.Author`) | `(R)`; `r.\|` and `R.\|` are `null` | `r.\|` gives `id; email; name; welcome` |
| Signature help for `run(` | `fn run(comptime R: type, comptime action: []const u8, base: R, input: (unknown type)) R`, with the doc comment | n/a |
| `const a = comptime find(R, action)` | hover `(Action(R))`; `a.\|` gives `name [[]const u8]; accept [[]const (unknown type)]; after [?(unknown type)]` | n/a |
| Loop captures: `inline for (a.accept) \|f\|`, `if (a.after) \|h\|`, `for (R.actions) \|a\|` | `((unknown type))`, `((unknown type))`, `(unknown)`; `a.\|` in the last is `null` | n/a |
| Source-written kernel type: `return .{ .\| }` for `Shape`, `shape.\|` in `gen.zig` | **works**: `name; field_names; field_types` | |
| Model access in the generator: `inline for (domain.resources) \|R\|`, then `inline for (R.actions) \|a\|` | `R` is `(unknown)`, `R.\|` is `null`, `a` is `(unknown)`; `domain.\|` itself lists `Author; Post; resources [struct { type, type }]` | |

Two half-way forms:

- **[measured]** `Generated` called with concrete arguments, `input: Generated(domain.Author, "RegisterInput")`: still `((unknown type))`, `input.|` is `null`. **[source]** ZLS does resolve `@field(x, "literal")` ([analysis.zig L2431-L2439](https://github.com/zigtools/zls/blob/0.17.0/src/analysis.zig#L2431-L2439)), but here the names arrive through parameters, not as string literals.
- **[measured]** A concrete alias beside the generic code, `const RegisterInput = api.Author.RegisterInput;` and a function typed on it: works fully (hover shows the struct, `in.|` gives `email`, `name`).

So an extension author writing generic behaviour is typing blind on anything that comes from the model: inputs, attribute lists, hook names, the resource itself. What they have is completion on the kernel's own source-written types, signatures with doc comments, go-to-definition between kernel functions, and compiler errors through build-on-save. A function written for one known resource gets the full experience, provided the stub does not shadow `api`.

## What ZLS says about itself

- **[docs]** ZLS 0.17.0 release notes: the split of the Zig build into configurer and maker "has broken critical build system integration features in ZLS. Most of them have since been restored using the build system protocol"; "various regressions remain that are anticipated to be resolved during the next release cycle"; "the new protocol lays the foundation for future improvements in ZLS and related tooling" ([release notes](https://zigtools.org/zls/releases/0.17.0/)). The listed regressions are package imports in `build.zig`, modules not tied to a compile step, and file watching on Windows. Generated files, module merging and freshness are not mentioned. Tracking issue: [zigtools/zls#3277](https://github.com/zigtools/zls/issues/3277), open. Read through an automated page summary.
- **[docs]** Zig 0.17.0 release notes, Build Server Protocol: clients can "Get notified when a build step starts and completes, including information about errors and which files were generated" and "Request specific steps to build"; "It is also planned for the build server to multiplex compiler server protocol for the compilation steps, providing type-system information, refactoring, and other advanced editing capabilities"; "Zig team and ZLS team are still working together to enhance the build server protocol further" ([release notes](https://ziglang.org/download/0.17.0/release-notes.html)). So the information ZLS would need to follow a regenerated file is already delivered to it; using it is not yet implemented. No issue or pull request proposing that was found.
- **[docs]** Build-on-save guide: opt in by declaring a `check` step (recommended) or setting `enable_build_on_save`; "If that results in errors, they will be displayed in your editor like any other diagnostic." It describes diagnostics only ([guide](https://zigtools.org/zls/guides/build-on-save/)).
- **[docs]** Multiple modules: [zigtools/zls#3183](https://github.com/zigtools/zls/issues/3183) "having multiple modules breaks `@import` resolution", open, same family as the stub result. Also [#3194](https://github.com/zigtools/zls/issues/3194) "Module not resolved if file is not referenced in root.zig", open.
- **[docs]** Generated files, historically: [zigtools/zls#394](https://github.com/zigtools/zls/issues/394) (2021, closed). A maintainer wrote then that generated paths set in a step's `make` function "will not be resolved as zls does not want to run make functions as they can be arbitrarily complex". 0.17.0 does run them, through the build server. [#2572](https://github.com/zigtools/zls/issues/2572), open: the error shown when a generator step fails is misleading.
- **[docs]** Watched files: [zigtools/zls#3305](https://github.com/zigtools/zls/issues/3305), closed, fixed on `master` after 0.17.0 (see Freshness above). No 0.17.1 exists as of this check (`gh release list`: latest is 0.17.0, 2026-10-19).
- **[docs]** Comptime-derived types: unchanged from the previous report (`docs/research/zls-comptime-derived-types.md` on branch `research/zls-derived-types`): no comptime interpreter, `@Struct`/`@Enum` unresolved, the fix is expected from compiler-served type information ([ziglang/zig#615](https://github.com/ziglang/zig/issues/615)).

## Not verified

- Behaviour inside an actual editor. Only raw LSP was recorded. In particular, whether VS Code, Neovim or Zed deliver `didChangeWatchedFiles` for files under `.zig-cache`, and whether a rewrite of a file is reported as `Changed` or as `Deleted` plus `Created`, was not tested; the driver sent those events itself.
- ZLS with the #3305 fix. `master` needs Zig `0.18.0-dev`, and building a patched 0.17.0 from source was not permitted in this session. The claim that a stable path plus that fix gives automatic freshness is inferred from the fix and from the measured `Deleted`/`Created` behaviour, not measured.
- Whether saving `build.zig` could be triggered automatically (an editor task, a file touched by the build) was not tried. The driver "saved" it by sending `didSave` with unchanged content.
- A stable path inside the cache directory (for example `.zig-cache/zava/api.zig`) was not tried; only `generated/api.zig` in the source tree. It should behave like `source_tree`.
- Timings are for a two-resource domain on one machine, measured by polling every 0.25 s. Generation time for a realistic domain, and `-fincremental`, were not measured. The first-ever load also compiles the build runner; that cost is inside the 5 s figure but was not separated out.
- The freshness edit was always a change to an existing action. Adding a resource or an action (new names rather than new fields) was not tried; the mechanism is the same.
- A dependency on a packaged `zava` (through `build.zig.zon`) was not tried: everything is one package. The release notes list regressions for modules reached through dependencies.
- `real_first` depends on the order ZLS visits steps; only one ordering was tried. `no_stub` was verified to build only for this prototype's `domain.zig` and `zava.zig`.
- In question 2 only literal completion, hover and go-to-definition were probed; not rename, references or semantic tokens. The `accept` member gap was probed in two spellings only.
- The reason D2 and D3 complete option names but not `.primary_key = .|`, while D4 does, was not traced in the source.
- Only macOS aarch64. The release notes say file watching in the build server is broken on Windows, which affects build-on-save there.
- The ZLS issue tracker was searched by keyword through `gh`; absence of an issue about following regenerated files is "not found", not "does not exist". Zig's tracker on Codeberg was not searched.

## Sources

- ZLS 0.17.0 source: [src/bsp.zig](https://github.com/zigtools/zls/blob/0.17.0/src/bsp.zig), [src/Server.zig](https://github.com/zigtools/zls/blob/0.17.0/src/Server.zig#L1165-L1167), [src/DocumentStore.zig](https://github.com/zigtools/zls/blob/0.17.0/src/DocumentStore.zig#L878-L911), [src/features/completions.zig](https://github.com/zigtools/zls/blob/0.17.0/src/features/completions.zig#L1245-L1457), [src/analysis.zig](https://github.com/zigtools/zls/blob/0.17.0/src/analysis.zig#L2431-L2439)
- ZLS `master` at `066658e` (2026-11-08): `src/bsp.zig`, `src/DocumentStore.zig`, `build.zig.zon`; commit [4c6b1c3](https://github.com/zigtools/zls/commit/4c6b1c33cdc1911ed0cc61e1480cd96bf23a9f3e)
- ZLS documentation: [0.17.0 release notes](https://zigtools.org/zls/releases/0.17.0/), [Build-On-Save guide](https://zigtools.org/zls/guides/build-on-save/)
- ZLS tracker: [#3277](https://github.com/zigtools/zls/issues/3277), [#3305](https://github.com/zigtools/zls/issues/3305), [#3183](https://github.com/zigtools/zls/issues/3183), [#3194](https://github.com/zigtools/zls/issues/3194), [#394](https://github.com/zigtools/zls/issues/394), [#2572](https://github.com/zigtools/zls/issues/2572), [#3196](https://github.com/zigtools/zls/issues/3196), [#1549](https://github.com/zigtools/zls/issues/1549), [#1525](https://github.com/zigtools/zls/issues/1525), [#3205](https://github.com/zigtools/zls/issues/3205)
- Zig: [0.17.0 release notes](https://ziglang.org/download/0.17.0/release-notes.html) (Build Server Protocol; Separate the Maker Process from the Configurer Process), standard library source of the installed 0.17.0 (`std/Build/Step/Run.zig`, `std/meta.zig`, `std/enums.zig`)
- Previous measurement: `docs/research/zls-comptime-derived-types.md` on branch `research/zls-derived-types`
- Measurements: `docs/research/zls-generated-source-and-declarations/results/summary.txt` and `raw.json`
