# PROTOTYPE: extension mechanism

Throwaway code for the wayfinder ticket "Extension mechanism" (issue #10). Never merged.

Question: how does an extension add to the model without the kernel knowing about it? One extension (`postgres.zig`) brings its own typed options for a resource and for an attribute, reads the normalized model, and contributes through each of the three ways ADR 0003 allows: comptime, descriptions, and build-run code. The kernel (`zava.zig`) never names it.

Zig 0.17.0 (pinned in `mise.toml`), macOS arm64.

## Run

    zig build run                                   # app against generated source
    zig build && cat zig-out/api.zig                # the generated source (saved in generated_sample.zig)
    zig build zava                                  # list extension commands
    zig build zava -- postgres.migrate migrations   # build-run code: writes migrations/0001.sql and snapshot.txt
    python3 errors.py                               # 15 mistakes, where the compiler points (saved in errors.txt)
    zig run probe_sibling_declaration.zig           # the rejected-candidate spelling

Everything above is saved in `output.txt`.

## The shape prototyped

- **Registration**: the domain root lists extensions beside resources (`pub const extensions = .{postgres};`). The kernel reads that list; `build.zig` only wires modules.
- **Where options live**: inside the `resource` declaration, in an `extensions` block keyed by extension name. The kernel derives the block's type from the registered list; each entry's type is the extension's own `Options(R)`. Per-attribute options are the extension's own keyed block, built with the kernel's public `zava.PerAttribute(R, T)`.
- **Contract**: an extension is a file with `name`, `Options(R)`, `Lowered` (plain data), `lower(R, resource, ?Options(R))`, and optionally `describe(R)`, `actionDoc(R, action)` and `commands`. `zava.options(E, R)` gives any comptime code an extension's normalized options.
- **The model has one form**: plain data with no `type` in it, so the comptime value is also the runtime value. Comptime code that needs the type takes `R` beside it.
- **Descriptions**: a struct, an enum, or a function. A type inside one is either an existing type (given as a `type` value; the emitter finds the spelling) or the name of another described type, optionally wrapped in optional or slice. A function names its delegate as an enum literal of the extension's own declarations and is emitted as `return ext.delegate(domain.R, params...)`.
- **Build-run code**: `commands` is a namespace of functions taking `zava.Command(E)` (I/O, allocator, the model, the extension's lowered options for every resource, arguments). One kernel runner executable dispatches `<extension>.<command>`.

## Findings

1. **The kernel stays ignorant.** `zava.zig` contains no extension name. Adding the extension took one line in the domain root and module wiring in `build.zig`.
2. **Developer mistakes in extension options are compiler errors on the exact token** (mistakes 1 to 4, 7), the same quality as the kernel's own options, with no check written by anyone. That includes an unregistered extension and a misspelled extension name, because the `extensions` block is a struct with one field per registered extension.
3. **An extension's own rules are resource-level errors** (5, 6): the `@compileError` is in the extension, the message names resource and attribute, and the developer's file does not appear. Same weakness as the kernel's weakest error in ADR 0001.
4. **Extension-author mistakes split in two.** Caught in the extension's source or by a kernel message naming the extension and description: a missing delegate (10, exact token, because the delegate is an enum literal over the extension's declarations), an unspellable type (12), a name collision (14), a missing contract member (15). Caught only in generated source: a reference to a described type that does not exist (11) and a delegate whose signature disagrees with its description (13). Both of the latter could be checked by the emitter before writing; the prototype does not.
5. **A `type` value is enough to describe an existing type.** The emitter spells primitives, optionals, const slices, records (`domain.Author`) and public declarations of the extension (`postgres.Limit`) by walking type info. No type-name strings and no source text cross from the extension. Anything else is a compile error naming the description.
6. **Three description kinds covered the example**: struct, enum, function. Not needed here: unions, methods on a described type, generic functions, error sets, default field values.
7. **Comptime behaviour typed on generated types works unchanged from ADR 0003**: `postgres.get(comptime R, pk: zava.Generated(R, "PrimaryKey"))`, and a `switch` over a generated enum with `inline else` producing comptime SQL per tag.
8. **One model form is enough.** The runner prints and diffs the same `zava.model` value the comptime code reads; nothing was lowered twice. The extension's `Lowered` must also be plain data, which the kernel does not enforce here.
9. **Build-run code needs no registration beyond `commands`.** Because the runner imports the domain, it reaches the extension's functions directly. `build.zig` has one generic step; a named step per command (`zig build migrate`) would need the name repeated in `build.zig`, since the build script cannot read the domain at configure time.
10. **Sibling declaration loses** (`probe_sibling_declaration.zig`): `pub const postgres = postgres.Options(@This()){...}` is `error: ambiguous reference`, and a misspelled declaration name is silently ignored. Finding declarations by type instead of by name would resolve hook signatures, which may mention generated source that does not exist yet.
11. **Trap for extension authors**: `@This()` inside the nested `commands` namespace is the namespace, not the extension. The prototype uses a file-level `const Self = @This();`.
12. **`table` left the kernel declaration.** It is a `postgres` option here; ADR 0001 lists it among kernel options.

## Not exercised

Two extensions at once (collision check is written but only hit against the kernel); one extension reading another's options; an extension adding options to an action or a relationship; ZLS behaviour inside the `extensions` block; packaging an extension as a separate Zig package with its own `build.zig`; build-run code handing data back to the program (left closed by ADR 0003).
