# PROTOTYPE: declaration surface

Throwaway code for the wayfinder ticket "Declaration surface" (issue #6). Never merged.

Question: how should a developer declare a domain? The same blog domain (`author` has many `post`; five actions) is written in four candidate shapes, each lowered to one normalized model (`core.zig`), and the same seven mistakes are made in each.

Zig 0.17.0 (pinned in `mise.toml`), macOS arm64.

## Run

    zig build run               # all four shapes, same derivations (saved in output.txt)
    zig build gen               # the source shape D generates (saved in generated_sample.zig)
    python3 errors.py           # seven mistakes x four shapes (saved in errors.txt)
    cat probes.txt              # two side probes

## The four shapes

| | declaration | frontend | lines to declare |
|---|---|---|---|
| A data literals | `domain_a.zig` | `shape_a.zig`, 14 lines | 45 |
| B annotated structs | `domain_b.zig` | `shape_b.zig`, 85 lines | 51 |
| C builder functions | `domain_c.zig` | `shape_c.zig`, 78 lines | 29 |
| D build-step generated | `domain_d.zig` | `gen.zig` 64 lines + `build.zig` | 42 |

All four produce byte-identical table SQL and routes. A derivation written against the normalized model cannot tell which shape declared it, so "easiest to introspect" is decided by what each shape costs to lower, not by what extensions see.

## Where the compiler points for each mistake

"Exact" means the error is on the offending token in the developer's file. "Resource" means the framework's `@compileError` line, with a note on the `Resource(.{` line. "Domain" means a note on the `Domain(.{ ... })` line only. "None" means the developer's file does not appear in the output at all.

| mistake | A literals | B structs | C builder | D generated |
|---|---|---|---|---|
| 1 action accepts misspelled attribute | resource | **exact, compiler-native** | call line | none |
| 2 relationship to missing resource | domain | **exact, compiler-native** | domain | none |
| 3 has_many key not on destination | domain | **exact, compiler-native** | domain | none |
| 4 duplicate attribute | resource | **exact, compiler-native** | call line | none |
| 5 misspelled option | exact | exact | exact | exact |
| 6 type with no Postgres mapping | resource | domain | call line | none |
| 7 app code misspells record field | exact, unreadable type name | exact, `domain_b.Author` | exact, unreadable type name | exact, `generated.Author` |

Full compiler output: `errors.txt`.

## Findings

1. **B turns the common mistakes into ordinary Zig errors.** Because the record is a struct the developer wrote, attribute names in `accept`, `primary_key` and relationship keys are enum literals typed against `std.meta.FieldEnum(@This())`. A typo is reported by the compiler on the exact token with no framework check involved (mistakes 1, 3). A duplicate attribute is a duplicate struct field (4). A missing destination is an undeclared identifier (2).
2. **B can name the other resource by type; A and C cannot.** `zava.hasMany("posts", Post, .author_id)` inside `Author` and `belongsTo(@This(), "author", Author, ...)` inside `Post` compile, because declarations inside a struct are resolved lazily. The same mutual reference between two `zava.Resource(.{ ... })` results is `error: dependency loop with length 2` (`probe_a_type_refs.zig`). A and C are confined to string names, resolved late in `Domain()`.
3. **B's record keeps its own name** (`domain_b.Author`); A and C get `core.RecordOf(.{ .name = &.{ ... }[0..(...)], ... })` in every error that mentions the record (7). This is the comptime spike's finding 3, confirmed for a two-resource model.
4. **B's worst error is the one where the field itself is wrong** (6): the type check runs inside `Resource()`, reached from `Domain()`, so the note is on the domain line. The message names the resource and attribute.
5. **B's cost: what a field cannot say lives away from the field.** `primary_key`, `generated` and anything per-attribute sit in the `resource` declaration, keyed by field name. `probe_b_attr_options.zig` shows that this can be typed: a derived struct with one optional entry per field makes `.email = .{ .unique = true }` checked, and `.emial` an exact compiler-native error. The declaration is the longest of the four (51 lines).
6. **C localizes framework errors to the line**, since each call is its own comptime step (1, 4, 6). But checks can only see what was declared above the call: an action must come after its attributes. Cross-resource errors are no better than A. It is the shortest (29 lines), and the least like data: the model exists only after the chain runs.
7. **A's errors are the comptime spike's**: located to the resource, never the line, unless the mistake is in the shape of the literal.
8. **D gives the worst declaration errors.** The generator is a separate compilation whose root is `gen.zig`; a model mistake is reported in `core.zig` with a note in `gen.zig`, and the developer's file is not mentioned (1 to 4, 6). The message text is the only locator.
9. **D gives the best consumer surface**: `generated.Author`, `generated.Post.DraftInput`, methods on records (`Post.draft(...)`, `post.author()`), and whole-model validation whether or not anything references a resource. `generated_sample.zig` is plain readable Zig.
10. **D's declaration is A's.** The generator needs the model as comptime data, so D is not a fourth way to write the domain: it is a different way to consume a declaration, and could sit behind A, B or C. Wiring cost is about 15 lines of `build.zig` per project.
11. **Lowering cost**: A is free (the literal is the model). B reflects once (about 40 lines). C accumulates slices with `++`. All three end at the same `Res` value, so extensions are unaffected by the choice.

## Not exercised

Calculations, validations, policies or anything holding an expression; action bodies with custom logic; attribute options beyond primary key and generated in the main comparison; ZLS completion and hover; a resource split across files; a model large enough to stress the branch quota per shape.
