# Editor support for comptime-derived types (ZLS 0.17.0)

Research for issue #11. Question: can Zava's developer-facing surface be comptime-only (types built with `@Struct` / `@Enum`), or does an editor need generated plain Zig source to be useful?

Measured on 2026-11-11. Statements are tagged **[measured]** (raw LSP responses from the real server, recorded in `zls-comptime-derived-types/results/`) or **[source]** / **[docs]** (read from ZLS source, documentation or issue tracker, not exercised).

## Answer

**[measured]** ZLS 0.17.0 resolves every type produced by `@Struct` or `@Enum` to `(unknown type)`. On a comptime-derived surface the editor gives no field completion, no action-name completion, no hover type, no go-to-definition on fields, and no literal-field inlay hints for the derived input and action types. The same domain written as plain structs and functions gets all of these. What survives on the comptime surface is everything that touches only user-written types: the record returned by `run` (`Author`, `Post`) completes, hovers and navigates normally, and parameter-name hints and signature help still show parameter names.

**[measured]** Diagnostics are the one area with parity. ZLS itself reports neither a misspelled field nor a misspelled action on either surface; with build-on-save both surfaces get the compiler's errors, at the right location, after saving.

**[measured]** No cheap variation recovers the lost capabilities. A named alias, a namespace function, literal-argument `@Struct`/`@Enum` with no loop, a `switch` over declared types, and even a type function that only returns `R.ActionName` all stay `(unknown type)`.

**[source]** This is a design limit of the current ZLS analysis backend, not a bug in this version: there is no comptime interpreter (removed in 2024), the type-resolution code has no case for `@Struct`/`@Enum`, and the maintainers' stated path to fixing it is a compiler-served type-information protocol (ziglang/zig#615) that is still open.

## Versions and how they were obtained

| Tool | Version | Source |
| --- | --- | --- |
| Zig | 0.17.0 | mise, directory-scoped pin (`zig = "0.17.0"`) |
| ZLS | 0.17.0 (tagged release, published 2026-10-19; `zls --version` prints `0.17.0`; `serverInfo` = `{"name":"zls","version":"0.17.0"}`) | mise, directory-scoped pin (`zls = "0.17.0"`, backend `aqua:zigtools/zls`, which downloaded the release asset `zls-aarch64-macos-0.17.0.tar.xz`). sha256 of the binary: `157cd6404052c6d419fbb0b0c1355b302a939bae09a9578cd8711ab44161dac3` |
| Platform | macOS (Darwin 25.3.0), aarch64 | |

A tagged 0.17.0 release exists, so no source build was needed. No global tool configuration was changed; the pin lives in `zls-comptime-derived-types/mise.toml`.

## Method

Files, all under `docs/research/zls-comptime-derived-types/`:

- `derived.zig`: the comptime surface. `ActionName(R)` (`@Enum`), `Input(R, action)` (`@Struct`), `run(comptime R, comptime action: ActionName(R), input: Input(R, action)) Error!R`, a typed hook, two resources (`Author`, `Post`) with two actions each, plus the alias, namespace-function and control variations.
- `generated.zig`: the same domain as plain source (`Author.RegisterInput`, `Author.register(input)`, `Post.DraftInput`, ...), modelled on `generated_sample.zig` from the `prototype/declaration-surface` branch.
- `variations.zig`: eight further ways of producing a type at comptime, to locate the boundary.
- `derived_bad.zig`, `generated_bad.zig`: one misspelled field and one misspelled action each.
- `build.zig`: a `check` step compiling all of them (what build-on-save runs).
- `lsp_driver.py`: starts `zls`, speaks JSON-RPC over stdio, and records every response. Cursor positions are found from anchor strings in the source, not hard-coded. For completion probes the document is edited in memory (`didChange`) to the incomplete form, for example `run(Author, .register, .{ . })`.
- `results/summary.txt` (digest) and `results/raw.json` (every raw response, server capabilities, logs).

All good files compile and run on Zig 0.17.0. ZLS was given `zig_exe_path` through `workspace/configuration`; the log shows no warnings or errors during the feature probes. (An earlier run in which ZLS could not find `zig` produced identical feature results, so the type-resolution findings do not depend on the standard library being resolved.)

To rerun:

```sh
cp -r docs/research/zls-comptime-derived-types /tmp/zls-probe && cd /tmp/zls-probe
mise trust && mise install
python3 lsp_driver.py --zls "$(mise which zls)" --zig "$(mise which zig)" --workspace . --out results
```

## Results: comptime-derived versus generated-style

All rows **[measured]**. Evidence is quoted from `results/summary.txt`; `null` is the literal LSP response.

| Capability | Comptime-derived (`derived.zig`) | Generated-style (`generated.zig`) |
| --- | --- | --- |
| Field completion inside the input literal, `run(Author, .register, .{ .\| })` | **Fails.** `null`. Also `null` for `run(Post, .draft, .{ .\| })` and for `var in: Input(Author, .register) = .{ .\| }` | **Works.** `2 items: email [[]const u8]; name [[]const u8]`; Post draft gives `author_id`, `title`, `body` |
| Action-name completion, `run(Author, .\|` | **Fails.** `null` in four forms (closed call, unclosed call, `Post`, inside `Input(Author, .\|)`) | **Works.** `Author.\|` gives `RegisterInput [type]; register [fn (input: RegisterInput) error{...}!Author]; RenameInput [type]; rename [...]` |
| Hover on the `input` argument at the call | **Partial.** Shows the declaration text, type is `((unknown type))` | **Works.** `(RegisterInput)` plus a link to the struct |
| Hover on a variable declared as `Input(Author, .register)` | **Partial.** Same: source text, then `((unknown type))`. Hook parameter: `(*(unknown type))` | **Works.** `(RegisterInput)`, hook parameter `(*RegisterInput)` |
| Hover on the result of `run` | **Works.** `(Author)` with link; `(Post)` for the second resource | **Works.** `(Author)`, `(Post)` |
| Hover on the callee | **Partial.** Source signature shown; resolved type `fn (comptime type, comptime (unknown type), (unknown type)) error{...}!R` | **Works.** `fn (RegisterInput) error{...}!Author` |
| Hover on a field of the derived value (`in.email`), or on the `.register` literal | **Fails.** `null` | **Works.** `email: []const u8` |
| Field completion on a variable of the derived type, `in.\|` | **Fails.** `null`. Through the hook's pointer parameter: `1 items: * [(unknown type)]` | **Works.** `email`, `name`; through the pointer: `*`, `email`, `name` |
| Field completion on the returned record, `a.\|` | **Works.** `id [i64]; email [[]const u8]; name [[]const u8]`; `Post` gives all five fields | **Works.** Same |
| Go-to-definition on the derived type | **Partial.** Jumps to `pub fn Input` (`derived.zig:35:8`), the type function, which shows no field list. `typeDefinition` on the variable returns the variable's own type annotation (`derived.zig:86:13`) | **Works.** Jumps to `RegisterInput = struct {` (`generated.zig:12:31`) |
| Go-to-definition on a field of the derived type (`in.email`, or `.email` in the literal) | **Fails.** `null` | **Works.** `generated.zig:13:9` |
| Go-to-definition on the action (`.register` versus `Author.register`) | **Fails.** `null` | **Works.** `generated.zig:16:12` |
| Go-to-definition on a field of the returned record | **Works.** `derived.zig:9:5` | **Works.** `generated.zig:9:5` |
| Signature help inside the call | **Partial.** Parameter names and active parameter are right, types are lost: `fn run(comptime R: type, comptime action: (unknown type), input: (unknown type)) error{...}!R`. This is less than the source text, which at least says `ActionName(R)` | **Works.** `fn register(input: RegisterInput) error{...}!Author` |
| Diagnostics from ZLS itself (build-on-save off) | **None.** `[]` for the misspelled field and the misspelled action | **None.** `[]` for both |
| Diagnostics with build-on-save | **Works.** `no field named 'emial' in struct 'derived.Input(derived.Author,.register)'` and `enum 'derived.ActionName(derived.Author)' has no member named 'regster'`, both at the misspelling | **Works.** `no field named 'emial' in struct 'generated.Author.RegisterInput'` and `struct 'generated.Author' has no member named 'regster'` |
| Inlay hints | **Partial.** Parameter-name hints work (`R:`, `action:`, `input:`) and the result gets `: Author`. No type hints on the fields of the input literal | **Works.** Result `: Author`, and each literal field gets its type (`: []const u8`, `: i64`, `: ?[]const u8`, `: bool`). No parameter-name hint because ZLS skips single-argument calls by default |

Both resources and both actions behaved identically in every row, so this is not a single-case result.

### Diagnostics and build-on-save configuration

**[measured]** With `enable_build_on_save` left at its default (`null`), ZLS published the compiler errors for both bad files because `build.zig` declares a step named `check`. Setting it to `true` gave the same result. Setting it to `false` gave no semantic diagnostics at all. Requirements observed:

- a `build.zig` in the workspace with a `check` step that compiles the code (not installing it);
- ZLS must be able to find `zig` (via `PATH` or `zig_exe_path`). When it could not, build-on-save silently produced nothing;
- the file must be saved: the errors come from the files on disk, not the unsaved buffer.

**[docs]** The build-on-save guide says the default command is `zig build check --watch`, that the feature is opt-in by declaring a `check` step or setting `enable_build_on_save`, and that `build_on_save_args` can add `-fincremental` ([guide](https://zigtools.org/zls/guides/build-on-save/)). The option text in ZLS 0.17.0: "Will be automatically enabled if the `build.zig` has declared a 'check' step" ([Config.zig](https://github.com/zigtools/zls/blob/0.17.0/src/Config.zig)).

**[measured]** The compiler stops at the first error in a function, and an error in a callee with an inferred error set hides errors in later callers; the first version of the bad files showed only one of the two errors for this reason. This affects both surfaces equally.

## Variations

All **[measured]**, in `derived.zig` (first three) and `variations.zig` (V1 to V8).

| Variation | Helped? | Evidence |
| --- | --- | --- |
| Named alias, `const RegisterInput = Input(Author, .register);` | **No.** | Variable hover `((unknown type))`; `aliased.\|` and `.{ .\| }` return `null`; go-to-definition on a field `null`. Only the alias declaration itself hovers, as `(type)` with its doc comment |
| Namespace function, `Api(Author).In(.register)` and `Api(Author).call(.register, in)` | **No** for the derived types. | `Api(Author).\|` lists `Name`, `In`, `call`, and the result of `call` resolves to `Author`. But `ns_in` hovers `((unknown type))`, action completion and literal-field completion return `null`, signature is `fn call(comptime action: (unknown type), input: (unknown type))` |
| Control: user-written record as a parameter type, `fn control(author: Author)` | **Works** (as expected). | Hover `(Author)`, `author.\|` gives three fields, go-to-definition on the field works |
| V1: `@Struct` with literal arguments, no loop or function | **No.** | Hover `((unknown type))`, completions `null`. The limit is the builtin, not the complexity of the comptime code |
| V2: `@Enum` with literal arguments | **No.** | Hover `((unknown type))`, `.\|` returns `null` |
| V3: classic generic, `fn V3(R) type { return struct { email: @FieldType(R, "email"), record: R }; }` | **Partly.** | Hover `(V3(Author))`; `v3.\|` lists `email` and `record [Author]`; as a parameter type (V8) the call literal completes both fields. But the type of `email` is `(unknown)` (ZLS does not evaluate `@FieldType(R, ...)` through the generic parameter), and `.{ .\| }` on a typed declaration returned `null` |
| V4: type function that only selects a declared type, `fn V4Name(R) type { return R.ActionName; }` | **No.** | `const v4b: V4Name(Author)` hovers `((unknown type))`, `.\|` returns `null` |
| V5: `switch` on a comptime enum value choosing among declared structs | **No.** | Hover `((unknown type))`, all completions `null` |
| V6: generic namespace with a declared function whose parameter is `R.RegisterInput` | **Partly.** | `V6(Author).\|` lists `register`, and the result completes as `Author`. The parameter type is `(unknown type)`, so literal-field completion returns `null`, also through `const AuthorV6 = V6(Author)` |
| V7: `std.meta.FieldEnum(Author)` | **No.** | Hover `((unknown type))`, `.\|` returns `null`. The standard library's own derived enum has the same problem |

Reading across the variations: ZLS follows a type function only when it returns a struct literal written in source (V3), and it binds a generic parameter used directly as a type (`record: R`, return type `R`). It does not follow a declaration looked up through a generic parameter (`R.ActionName`, `R.RegisterInput`), does not evaluate `@FieldType` through one, and does not evaluate `switch`, `@Struct` or `@Enum` at all. For Zava this means a comptime-only surface cannot be made editor-friendly by reshaping the comptime code; the input and action types have to exist as source text in a non-generic position for ZLS to see them.

## What ZLS says about itself

- **[docs]** README at the 0.17.0 tag: "ZLS supports most language features, including simple type function support, payload capture type resolution, custom packages, and others. Support for comptime and semantic analysis is Work-in-Progress." ([README](https://github.com/zigtools/zls/blob/0.17.0/README.md))
- **[source]** Type resolution of builtin calls is a hand-written switch in `src/analysis.zig`. At 0.17.0 it has cases for `@This`, `@as`, `@TypeOf`, `@import`, `@FieldType`, `@field`, `@EnumLiteral`, `@Vector` and some arithmetic builtins. Everything else, including `@Struct` and `@Enum`, falls to the `else` branch that returns the builtin's documented return type, here just `type` ([analysis.zig L2305-L2473](https://github.com/zigtools/zls/blob/0.17.0/src/analysis.zig#L2305-L2473)). This matches the measured hover on the alias (`(type)`) and on values (`(unknown type)`). The same file on `master` at commit `066658e` (2026-11-08) still has no `@Struct` or `@Enum` case.
- **[source]** `src/analyser/README.md` at 0.17.0: "This directory contains mostly future work on an improved analysis backend. Only a fractions of this code is being used."
- **[docs]** The comptime interpreter was removed in July 2024. The maintainer's explanation: it "never went beyond the proof-of-concept stage"; a ZIR-based replacement branch (`techatrix/stage2-sema`) "frequently breaks and I currently do not have the time to continue working on it"; and "With the addition of ziglang/zig#615, ZLS could also be provided type information from the compiler." ([zigtools/zls#1980](https://github.com/zigtools/zls/pull/1980))
- **[docs]** Open tracking issue: "In its current state, ZLS is only able to report syntax errors and errors that are provided by `zig ast-check`. Everything else (like semantic analysis) is not available... The most viable solution right now is the build-on-save feature." A maintainer answered the exact question asked here (2025-10-15): "ZLS's build-on-save feature in it's current form is only providing diagnostic messages. With ziglang/zig#615, ZLS can interface with the compiler to acquire diagnostic messages as well type information that can the be used for autocompletion and much more." ([zigtools/zls#2017](https://github.com/zigtools/zls/issues/2017), [comment](https://github.com/zigtools/zls/issues/2017#issuecomment-3406961967))
- **[docs]** Open bug with the same symptom on a reified enum: "Comptime Enum Auto complete not working ... UserField is showing `(unknown type)`", labelled `bug`, no fix linked ([zigtools/zls#2515](https://github.com/zigtools/zls/issues/2515)). A related open enhancement since January 2024: [zigtools/zls#1724](https://github.com/zigtools/zls/issues/1724).
- **[docs]** Planned work that would change the picture: the compiler-served protocol, [ziglang/zig#615](https://github.com/ziglang/zig/issues/615) "Implement a server in the compiler that serves information about the compilation", open on GitHub as of this check. Improvements to generic-parameter tracking have landed incrementally ([zigtools/zls#2133](https://github.com/zigtools/zls/pull/2133), "track comptime types"), and a PR for comptime integer arithmetic is open ([zigtools/zls#2650](https://github.com/zigtools/zls/pull/2650)); neither addresses type reification.
- **[docs]** The 0.17.0 release notes do not mention comptime, type reification or analysis-backend changes; they cover rename behaviour and build-system integration regressions ([release notes](https://zigtools.org/zls/releases/0.17.0/)). Read through an automated page summary, not line by line.

## Not verified

- Behaviour inside an actual editor (VS Code, Neovim, Zed). Only raw LSP responses were recorded; an editor could add or hide things (for example word-based fallback completion), but it cannot obtain type information ZLS does not return.
- Semantic tokens, find-references, rename and code actions on derived types were not probed.
- ZLS `master` was not built or run. The claim that it still lacks `@Struct`/`@Enum` handling comes from reading `src/analysis.zig` at one commit.
- Other language servers or compiler-backed tools for Zig were not surveyed.
- The current status and schedule of ziglang/zig#615 beyond "open on GitHub". Zig's issue tracking may have moved; the GitHub page was not cross-checked against another tracker, and no date for the protocol was found.
- Build-on-save latency on a realistic project, and `-fincremental`, were not measured. The probe project is five small files.
- Whether build-on-save reports errors for unsaved buffers was not tested; the statement that it needs a save follows from the guide and from how the driver triggered it (files on disk, `didSave`).
- Only macOS aarch64 was tested. The release notes mention a file-watching regression on Windows that affects build-on-save there.
- A doc-comment workaround (documenting fields on the type function) was not tested beyond observing that hover on the alias declaration shows its doc comment.

## Sources

- ZLS 0.17.0 source: [README.md](https://github.com/zigtools/zls/blob/0.17.0/README.md), [src/analysis.zig](https://github.com/zigtools/zls/blob/0.17.0/src/analysis.zig#L2305-L2473), [src/Config.zig](https://github.com/zigtools/zls/blob/0.17.0/src/Config.zig), [src/analyser/README.md](https://github.com/zigtools/zls/blob/0.17.0/src/analyser/README.md)
- ZLS release: [0.17.0 tag](https://github.com/zigtools/zls/releases/tag/0.17.0), [release notes](https://zigtools.org/zls/releases/0.17.0/)
- ZLS guide: [Build-On-Save](https://zigtools.org/zls/guides/build-on-save/)
- ZLS tracker: [#1980](https://github.com/zigtools/zls/pull/1980), [#2017](https://github.com/zigtools/zls/issues/2017), [#2515](https://github.com/zigtools/zls/issues/2515), [#1724](https://github.com/zigtools/zls/issues/1724), [#2133](https://github.com/zigtools/zls/pull/2133), [#2650](https://github.com/zigtools/zls/pull/2650)
- Zig tracker: [ziglang/zig#615](https://github.com/ziglang/zig/issues/615)
- Measurements: `docs/research/zls-comptime-derived-types/results/summary.txt` and `raw.json`
