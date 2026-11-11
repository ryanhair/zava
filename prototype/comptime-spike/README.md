# PROTOTYPE: comptime thesis spike

Throwaway code for the wayfinder ticket "Comptime thesis spike" (issue #5). Never merged.

Question: does the central bet hold? One tiny resource declared as build-time data; derive a record type, SQL, and a JSON handler; find where build-time derivation breaks.

Zig 0.17.0 (pinned in `mise.toml`), macOS arm64, Debug. Timings are single runs.

## Run

    zig run main.zig                     # the happy path
    zig run probes/names.zig             # what names derived types get
    (cd errors && cat output.txt)        # compiler output for 11 deliberate mistakes
    (cd scale && python3 gen.py 200)     # emit a 200-resource model, comptime and hand-written

- `zava.zig`: the spike "framework", about 230 lines.
- `main.zig`: one `user` resource and its derived record, SQL and handler.
- `errors/`: one file per mistake; `output.txt` is what the compiler said.
- `scale/`: generator for big models and `timings.txt`.

## What held

- All three derivations work from one comptime `Spec` value with no runtime model: a `@Struct` record type, `create table` / `insert` / `select` text built with `++`, and a handler that parses a derived input type with `std.json`, fills the record with `inline for`, and serializes it. `std.json` parse and stringify accept `@Struct`-generated types unchanged.
- Action names derived into an `@Enum` make a misspelled action an ordinary type error at the call site.
- Compile cost is not a break point. 200 resources x 20 attributes x 2 actions:

  | | comptime | hand-written equivalent |
  |---|---|---|
  | semantic analysis only | 2.05 s, 127 MB | 0.60 s, 111 MB |
  | full Debug build | 4.44 s, 388 MB | 7.68 s, 832 MB |

  At 10 resources both are about 0.3 s analysis, 1.9 s full build. Derivation costs roughly 3x in analysis, which is small in absolute terms, and code generation and linking dominate either way.

## Where it broke or bent

1. **Errors land on the resource, not the line.** Every framework check (`duplicate attribute`, `accepts unknown attribute`, `no Postgres type`) reports at the `@compileError` inside the framework, with a "called at comptime here" note on the `zava.Resource(.{` line. The user's file and resource are identified; the offending attribute's line is not. The message text has to carry resource, action and attribute names, and does.
2. **Spec-shape mistakes are excellent.** A misspelled spec field (`.generatd`) or bad enum value (`.upsert`) points at the exact user line and column, because the spec is an ordinary typed struct literal.
3. **Derived type names are unreadable.** A record derived from a spec *value* is named `zava.RecordOf(.{ .name = &.{ ... }[0..(...)], .table = ... })`, and that string appears in every field-typo and type-mismatch error. Probe: the name is the innermost function call containing `@Struct`, with arguments serialized. Keyed on a user-named *type* instead of a value it becomes `RecordOf(main.UserSpec)`. A struct the user writes and the framework reflects on keeps its own name.
4. **The branch quota is per entry point.** `@setEvalBranchQuota` in `Resource()` did not cover `Input()` or `sql()`: each generic function the user calls starts again at 1000. A 60-attribute resource failed inside framework code until every entry point raised it. With 100 000 everywhere, 150 attributes pass and 300 fail on the quadratic duplicate check. Quota is a framework-internal concern that leaks to the user as a framework-internal error.
5. **Unused resources are never checked.** A resource with a duplicate attribute compiled cleanly because nothing referenced it (`errors/e10`). Validation only runs for what the program reaches.
6. **No methods on the record.** `record.save()` is `no field or member function named 'save'`. Behaviour has to live on the hand-written generic wrapper (`User.handle(.register, ...)`), which worked without friction here.
7. **Nothing was derivable as an error set.** The handler reports failures as `@errorName` strings; a per-action error set cannot be generated. Not exercised further.
8. **Structurally equal derived types are the same type.** Two derivations from equal comptime data are identical types (memoization). Harmless here, but two actions accepting the same attributes share one input type.

## Not exercised

Relationships across resources, filters and expressions, a real Postgres round trip, a real HTTP server, parameter binding, build-step code generation side by side, ZLS behaviour, incremental compilation.
