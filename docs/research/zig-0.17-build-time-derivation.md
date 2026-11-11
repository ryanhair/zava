# Zig 0.17 capabilities and limits for build-time derivation

Research for issue #3. Question: what does Zig 0.17 allow and forbid for a framework that derives everything (record types, SQL, handlers, validation, docs) from a domain model at build time?

## How this was verified

- **Zig 0.17.0 exists.** The official download index lists `0.17.0` (2026-10-01) and a bug-fix `0.17.1` (2026-11-02); master is `0.18.0-dev`. Source: <https://ziglang.org/download/index.json>.
- **Language reference**: the `doc/langref.html` shipped inside the 0.17.0 tarball (same content as <https://ziglang.org/documentation/0.17.0/>).
- **Release notes**: <https://ziglang.org/download/0.17.0/release-notes.html>, <https://ziglang.org/download/0.16.0/release-notes.html>, <https://ziglang.org/download/0.15.1/release-notes.html>.
- **Standard library source**: the `lib/std` and `lib/compiler` trees shipped inside the 0.17.0 tarball (the 0.17.0 tag of <https://codeberg.org/ziglang/zig>). File paths below are relative to `lib/`.
- **Experiments**: run locally with `zig version` = `0.17.0` on macOS arm64, Debug mode. Marked **[ran]**. Timings are one machine, one run: treat as order-of-magnitude.
- Anything not confirmed from those is marked **[unverified]**. 0.17.1 was not examined.

## Summary for designers

1. Comptime type generation is fully supported, through per-kind builtins (`@Struct`, `@Enum`, `@Union`, `@Tuple`, `@Int`, `@Pointer`, `@Fn`). `@Type` is gone.
2. A generated type has fields only: **no declarations, no methods, ever**. Methods must live on a hand-written generic wrapper, or the type must come from build-step code generation.
3. Error sets cannot be generated at comptime; tuples cannot be generated with comptime fields.
4. `usingnamespace` is gone, so mixing derived declarations into a user's struct is impossible. The official replacement is a zero-bit field plus `@fieldParentPtr`.
5. Comptime evaluation is an interpreter: budgeted by a branch quota (default 1000) that is shared by the whole evaluation, without heap allocators, and slow enough that large models cost real seconds.
6. Compile errors: `@compileError` with a comptime-formatted message is the only tool. No custom notes, no way to move the error location to the user's declaration.
7. I/O is an interface value, `std.Io`, passed like an allocator. `async`/`await` are library functions on it, not keywords. Only `Io.Threaded` is complete; the evented backends lack networking.
8. The build system directly supports "compile a generator, run it, import its output as a module" in one `zig build`, with caching. The generator can `@import` the user's domain module.

## 1. Generating types at comptime

### The builtins

`@Type` was removed in 0.16.0 and replaced with individual builtins ([0.16.0 notes, "@Type Replaced with Individual Type-Creating Builtin Functions"](https://ziglang.org/download/0.16.0/release-notes.html#Type-Replaced-with-Individual-Type-Creating-Builtin-Functions)). The 0.17.0 signatures ([langref, Builtin Functions](https://ziglang.org/documentation/0.17.0/#Builtin-Functions)):

```zig
@Struct(layout: std.lang.Type.ContainerLayout, BackingInt: ?type,
        field_names: []const []const u8,
        field_types: *const [field_names.len]type,
        field_attrs: *const [field_names.len]std.lang.Type.Struct.FieldAttributes) type
@Union(layout, ArgType: ?type, field_names, field_types, field_attrs) type   // ArgType = enum tag type or backing int
@Enum(TagInt: type, mode: std.lang.Type.Enum.Mode, field_names, field_values: *const [n]TagInt) type
@Tuple(field_types: []const type) type
@Int(signedness, bits: u16) type
@Pointer(size, attrs, Element: type, sentinel: ?Element) type
@Fn(param_types, param_attrs, ReturnType, attrs) type
@EnumLiteral() type
```

- Arguments are "struct of arrays": parallel arrays of names, types, attributes. `&@splat(.{})` gives default attributes for every field.
- `Struct.FieldAttributes` is `{ @"comptime": bool = false, @"align": ?usize = null, default_value_ptr: ?*const anyopaque = null }` (`std/lang.zig`). So generated fields can have default values and comptime fields.
- There is no `@Array`, `@Optional`, `@ErrorUnion`, `@Opaque`, `@Float`: write `[n]T`, `?T`, `E!T`, `opaque {}` directly (0.16.0 notes, same section).
- **[ran]** `@Struct`, `@Enum`, `@Union` all work as documented in 0.17.0, including a generated enum used as the tag of a generated union.

### What changed in 0.17 specifically

- `std.builtin` is deprecated in favour of **`std.lang`** (`std.builtin` is now an alias: `pub const builtin = lang;` in `std/std.zig`). Type info lives at `std.lang.Type`. ([0.17.0 notes, Deprecations](https://ziglang.org/download/0.17.0/release-notes.html#Deprecations))
- **`@typeInfo` output is now struct-of-arrays too**: `info.field_names`, `info.field_types`, `info.field_attrs`, `info.decl_names` replace `info.fields[i].name` / `.type` and `info.decls`. ([0.17.0 notes, "Struct-Of-Arrays Style for std.lang.Type"](https://ziglang.org/download/0.17.0/release-notes.html#Struct-Of-Arrays-Style-for-codestdlangTypecode); confirmed in `std/lang.zig`.) Idiom:

  ```zig
  const info = @typeInfo(S).@"struct";
  inline for (info.field_names, info.field_types) |name, T| { ... }
  ```
- `std.meta.fieldInfo`, `fieldNames`, `fieldTypes` are deprecated in favour of `@typeInfo` (0.17.0 Deprecations). `std.meta.FieldEnum` and `std.meta.ArgsTuple` still exist (`std/meta.zig`).
- `@hasDecl` now returns true **only for `pub` declarations**, regardless of which file asks ([0.17.0 notes](https://ziglang.org/download/0.17.0/release-notes.html#codehasDeclcode-Returns-codetruecode-Only-for-Public-Declarations)). Anything the framework detects on user types must be `pub`.
- New `@backingInt` / `@fromBackingInt` for enums and packed types (langref).

### Hard limits on generated types

| Limit | Source |
|---|---|
| **No declarations on generated types.** `@Struct`/`@Union`/`@Enum` take no decl argument; a generated type's `decl_names` is empty. | langref signatures; **[ran]** `r.save()` on a `@Struct` type: `error: no field or member function named 'save'` |
| **No generated error sets.** "it is no longer possible to reify error sets. Instead, declare your error sets explicitly using `error{ ... }` syntax." | 0.16.0 notes, same section |
| **No generated tuples with comptime fields.** | 0.16.0 notes, same section |
| **No `usingnamespace`** (removed 0.15), so derived decls cannot be mixed into a user-written struct. | [0.15.1 notes](https://ziglang.org/download/0.15.1/release-notes.html#usingnamespace-Removed) |
| Reflection sees decl **names** only (`decl_names`); get the value with `@field(T, name)`. | `std/lang.zig` |

The error-set limit matters for the "rich errors" open question: a derived per-action error set cannot be built from the model at comptime. Error sets can still be merged with `||` from hand-written sets, and inferred error sets still work.

### Standard workarounds for methods on derived types

1. **Generic wrapper with the generated type as an associated type or field.** Hand-written `fn Resource(comptime spec) type { return struct { pub const Row = Record(spec); row: Row; pub fn get(...) ... }; }`. Methods are generic code over the model; the generated struct is pure data. **[ran]**: works; `std.meta.FieldEnum(Row)` plus `@FieldType(Row, @tagName(f))` gives typed, comptime-checked field access.
2. **Free functions / namespaces taking the generated type**: `Users.insert(db, row)` rather than `row.insert(db)`.
3. **User writes the struct, framework reflects on it.** The user's own `struct` can carry `pub` decls (including a `pub const` model description) and methods; the framework reads fields with `@typeInfo` and decls with `@hasDecl`/`@field`. This inverts the direction: the struct is the declaration, not the output.
4. **Zero-bit mixin field + `@fieldParentPtr`**: the official `usingnamespace` replacement. A user struct includes `counter: CounterMixin(Foo) = .{}` and calls `foo.counter.increment()`. ([0.15.1 notes, "Use Case: Mixins"](https://ziglang.org/download/0.15.1/release-notes.html#Use-Case-Mixins))
5. **Build-step code generation**, which emits ordinary source and so has none of these limits (section 5).

### Type identity and naming

- **[ran]** Two calls to the same type-returning function with equal comptime arguments yield the **same type** (`Record(x) == Record(x)` is true): comptime calls are memoized.
- A generated type is named after the function call that returned it, with arguments serialized ([langref, Struct Naming](https://ziglang.org/documentation/0.17.0/#Struct-Naming)). **[ran]** With structured arguments this is poor: `t1.Resource("users"[0..5],&.{ .{ ... }, .{ ... } }[0..2])`. This string is what users see in compile errors and `@typeName`. A type assigned directly to a `const` gets that const's name (`t3.Row`), but only when the builtin call is the initializer itself.

### Related semantics changes (0.16)

- **Lazy field analysis**: a struct/union/enum is resolved only when its size or a field type is needed; using a type purely as a namespace no longer analyses its fields. ([0.16.0 notes](https://ziglang.org/download/0.16.0/release-notes.html#Lazy-Field-Analysis))
- **Dependency loops**: rules simplified, some new loops are errors, but the error now lists every edge of the loop. A model that refers to itself while being built (e.g. a default value computed from `@typeInfo` of the same struct) is a loop. ([0.16.0 notes, Reworked Type Resolution](https://ziglang.org/download/0.16.0/release-notes.html#Reworked-Type-Resolution))
- **Pointers to comptime-only types are runtime types**: a `[]const` slice of comptime-only structs can be passed to runtime code, which may load the runtime-typed fields (e.g. names) but not the `type` fields. Useful for exposing model metadata without a parallel runtime table. ([0.16.0 notes](https://ziglang.org/download/0.16.0/release-notes.html#Pointers-to-Comptime-Only-Types-Are-No-Longer-Comptime-Only))

## 2. Comptime limits

### Branch quota

- Default is **1000 backwards branches** per comptime evaluation; `@setEvalBranchQuota(n)` raises it, and a value lower than the current quota is ignored ([langref](https://ziglang.org/documentation/0.17.0/#setEvalBranchQuota)).
- **[ran]** The quota is **shared by the whole evaluation**, not per function. A callee may raise it, and that covers the callee; but the count is cumulative across everything reached from the top-level comptime expression. Three functions each setting 100 000 still failed with "exceeded 100000 backwards branches" when called 300 times from one comptime block. Consequence: the framework must set a generous quota at its own entry points, sized to the model, and users with big models may still need to raise it.
- `std.fmt.comptimePrint` burns quota quickly; the failure in the run above was inside `std/Io/Writer.zig`.

### Memory and allocation

- **No heap allocators at comptime.** **[ran]** `std.heap.FixedBufferAllocator` inside a `comptime` block fails: `ArrayList.appendSlice` returns `error.OutOfMemory`. Comptime code uses fixed-size arrays sized from comptime-known lengths, slices of them, and `++` concatenation.
- No documented limit on comptime memory was found in the langref or notes **[unverified: whether any cap exists]**. Memory is simply compiler RSS (figures below).
- `a ** n` array multiplication is **removed in 0.17**; use `@splat` ([0.17.0 notes](https://ziglang.org/download/0.17.0/release-notes.html#Array-Multiplication-Syntax-Removed)). `++` still works **[ran]**.
- `BoundedArray` was removed in 0.15; `ArrayList` gained `initBuffer` and `...Bounded` methods ([0.15.1 notes](https://ziglang.org/download/0.15.1/release-notes.html#Removal-of-BoundedArray)) **[unverified: whether `initBuffer` lists work at comptime]**.

### Strings and formatting

- `std.fmt.comptimePrint(fmt, args)` works at comptime and returns a comptime string **[ran]**. It is the practical way to build SQL text and error messages.
- `++` on comptime slices and arrays works **[ran]**.
- 0.17: `std.fmt.allocPrint` moved to the allocator (`gpa.print(fmt, args)`); new `{q}` / `{qf}` quoting specifiers ([0.17.0 notes](https://ziglang.org/download/0.17.0/release-notes.html#Formatted-Printing-Enhancements)). Runtime only.
- Since 0.15, custom `format` methods have the signature `pub fn format(self, w: *std.Io.Writer) std.Io.Writer.Error!void` and are invoked with `{f}` (confirmed in `std/SemanticVersion.zig` at 0.17.0; [0.15.1 notes](https://ziglang.org/download/0.15.1/release-notes.html#f-Required-to-Call-format-Methods)).

### Compile-time cost

**[ran]** A synthetic model: N resources of 20 fields each; per resource one `@Struct` and one `INSERT` statement built at comptime. `zig build-exe`, Debug, macOS arm64.

| Case | Wall time | Peak RSS |
|---|---|---|
| Trivial file, no codegen | 0.2 s | 0.1 GB |
| N=300, strings via `std.fmt.comptimePrint` | 7.1 s | 0.59 GB |
| N=300, strings via `++` and a hand-rolled integer formatter | 2.2 s | 0.31 GB |
| N=3000, `comptimePrint`, semantic analysis only (`-fno-emit-bin`) | 56.5 s | 1.95 GB |

Readings: cost is roughly linear in model size; `comptimePrint` is about 3x the cost of plain concatenation; the cost is semantic analysis, so it is paid on every non-incremental build of any file that references the derived values. A realistic model (tens of resources) is well under a second; a framework that formats heavily at comptime per attribute, per action, per derivation will be felt. Build-step codegen moves this cost into a cached step.

Profiling: `zig build --time-report --webui` shows per-declaration semantic-analysis time ([0.15.1 notes](https://ziglang.org/download/0.15.1/release-notes.html#Web-Interface-and-Time-Report); both flags present in `compiler/Maker.zig` at 0.17.0).

### Incremental compilation

- Opt-in: `zig build -fincremental --watch`. Still **not default**. 0.17.0: "it is now possible for most projects targeting x86_64-linux to take advantage of incremental compilation"; works with the LLVM backend for analysis-only speedups; a new Mach-O linker, the self-hosted aarch64 backend, and incremental without `--watch` are future work. ([0.17.0 notes](https://ziglang.org/download/0.17.0/release-notes.html#Incremental-Compilation), [0.16.0 notes](https://ziglang.org/download/0.16.0/release-notes.html#Incremental-Compilation))
- How well incremental compilation avoids re-running heavy comptime derivation after an unrelated edit was not measured **[unverified]**.

## 3. Compile-error quality

### What exists

- `@compileError(comptime msg: []const u8) noreturn` is the only user-level error builtin. The message can be built with `comptimePrint`, so it can name the resource, attribute, and index. There is **no builtin for attaching notes** or for choosing the reported source location (0.17.0 builtin list in the langref has `@compileError` and `@compileLog` only).
- `@compileLog` for debugging; it forces a compile error ([langref](https://ziglang.org/documentation/0.17.0/#compileLog)).
- The error fires only if the code is semantically analysed, so validation must sit on a path the user's code actually references.

### What a user sees **[ran]**

A duplicate-attribute check inside a library function, reached via `Resource(...)` → `Record(...)` → `validate(...)`:

```
t2.zig:9:17: error: resource 'users': duplicate attribute 'id' (attributes #2)
                @compileError(std.fmt.comptimePrint(...));
                ^~~~~~~~~~~~~
t2.zig:15:13: note: called at comptime here
    validate(name, attrs);
t2.zig:27:31: note: called at comptime here
        pub const Row = Record(name, attrs);
referenced by:
    t2.Resource("users"[0..5],&.{ .{ ... }, .{ ... }, .{ ... } }[0..3]): t2.zig:28:14
    main: t2.zig:39:21
    4 reference(s) hidden; use '-freference-trace=6' to see all references
```

- The primary location is the **`@compileError` line inside the framework**, not the user's declaration. The compiler adds "called at comptime here" notes for the comptime call chain and a "referenced by" trace, truncated by default (`-freference-trace=N` shows more).
- The user's own line (`const User = Resource("users", ...)`) did not appear in the default output; the trace showed where the type was *used*. So the message text must carry everything needed to find the mistake.
- Shallow call chains give shorter errors: each framework layer between the user and the `@compileError` adds a note.
- Mistakes the compiler catches itself are good and point at user code: unknown field on a generated struct gives `no field named 'nope' in struct 't3.Row'` plus `struct declared here`; a wrong enum literal for a derived field enum gives `enum 'meta.FieldEnum(t3.Row)' has no member named 'nope'` at the call site. Designing APIs so that mistakes become ordinary type errors (enum literals, field names, `@FieldType`) yields better errors than hand-written checks.
- Type names in messages are the serialized call (section 1); long comptime arguments are elided as `.{ ... }`.
- With build-step codegen, errors about a generated type point at the user's line and add a note into `.zig-cache/o/<hash>/generated.zig` **[ran]**, which the user can open and read.
- `zig build --error-style minimal` drops the step-tree preamble; `--multiline-errors` controls wrapping ([0.16.0 notes](https://ziglang.org/download/0.16.0/release-notes.html#Added-code--error-stylecode-Flag); both present in `compiler/Maker.zig` at 0.17.0).

## 4. I/O and async

### State in 0.17

- **All I/O goes through an `std.Io` value** passed as a parameter, like `Allocator` (introduced 0.16.0: "all input and output functionality requires being passed an `Io` instance"). It covers files, networking, processes, time, randomness, tasks, queues, and sync primitives ([0.16.0 notes, "I/O as an Interface"](https://ziglang.org/download/0.16.0/release-notes.html#IO-as-an-Interface); `std/Io.zig` header at 0.17.0). `Io` is `{ userdata: ?*anyopaque, vtable: *const VTable }`.
- **`async`/`await` keywords are removed** (0.15): "it is settled that there will not be async/await keywords in the language. Instead, they will be in the Standard Library as part of the Io Interface" ([0.15.1 notes](https://ziglang.org/download/0.15.1/release-notes.html#async-and-await-keywords-removed)). The 0.17.0 langref "Async Functions" section still says async functions regressed and are planned to return as a lower-level primitive (stackless coroutines) **[unverified: current status of that proposal]**.
- Concurrency API on `Io` (0.16.0 notes; functions present in `std/Io.zig` at 0.17.0):
  - `io.async(fn, args)` → `Future(T)`: expresses independence; infallible; an implementation may just call the function.
  - `io.concurrent(fn, args)`: requires real concurrency; can fail with `error.ConcurrencyUnavailable`.
  - `future.await(io)`, `future.cancel(io)`; `Io.Group` for many tasks with one lifetime; `Io.Queue(T)`; `Select`; `Batch` (operation-level).
  - Cancelation: cancelable operations include `error.Canceled` in their error sets; propagate it.
  - Sync primitives moved: `std.Io.Mutex`, `Condition`, `Semaphore`, `RwLock`, `Event`, `Futex` (replace `std.Thread.*`). `std.Thread.Pool` removed.
- Implementations at 0.17.0:
  - **`Io.Threaded`**: complete, tested, default from `main` (`std/start.zig`). Blocking syscalls on a thread pool.
  - **`Io.Evented`** = `Uring` (Linux), `Kqueue` (BSD), `Dispatch` (Apple): green threads. Described as experimental in 0.16.0. In the 0.17.0 source, `Uring` and `Dispatch` still wire `netListenIp`, `netAccept`, `netConnectIp` to `...Unavailable` stubs; `Kqueue` wires real ones. So **evented networking is not usable on Linux or macOS in 0.17.0**.
- **"Juicy main"**: `pub fn main(init: std.process.Init) !void` provides `init.io`, `init.gpa`, `init.arena`, args, environ ([0.16.0 notes](https://ziglang.org/download/0.16.0/release-notes.html#Juicy-Main)). **[ran]** in 0.17.0. Tests use `std.testing.io`.
- `std.heap.ArenaAllocator` is thread-safe and lock-free since 0.16; 0.17 replaces `DebugAllocator` with `SafeAllocator` and `StackFallbackAllocator` with `BufferFirstAllocator` (0.17.0 notes).

### Readers and writers ("Writergate", 0.15)

- `std.Io.Reader` and `std.Io.Writer` are **concrete, non-generic structs with the buffer in the interface**; `GenericReader`, `AnyReader`, `BufferedWriter`, `CountingWriter`, `FixedBufferStream` are deleted ([0.15.1 notes, Writergate](https://ziglang.org/download/0.15.1/release-notes.html#Writergate); [0.16.0 notes](https://ziglang.org/download/0.16.0/release-notes.html#Io-delete-GenericReader-AnyReader-FixedBufferStream)).
- Usage **[ran]**: `var fw = file.writer(io, &buf); const w = &fw.interface; try w.print(...); try w.flush();`. Forgetting `flush` loses output.
- Networking: `Io.net.IpAddress.listen(&addr, io, opts)` → `Server`; `server.accept(io)` → `Stream`; `stream.reader(io, buf)` / `stream.writer(io, buf)` (`std/Io/net.zig`).
- `std.http.Server.init(in: *Reader, out: *Writer)` takes the two stream interfaces and nothing else (`std/http/Server.zig`), so it is transport-agnostic and testable against in-memory buffers.

### What to write a server and database client against

- Take **`io: std.Io`** and an `Allocator` as parameters; never construct an `Io` inside the library. The application's `main` chooses the implementation.
- Parse and serialize protocols (HTTP bodies, the Postgres wire protocol) against **`*std.Io.Reader` / `*std.Io.Writer`**, so they work over any stream and in tests.
- Use `io.async` / `Io.Group` for per-connection tasks and `Io.Mutex`/`Io.Condition`/`Io.Queue` for a connection pool, so the same code blocks a thread under `Threaded` and switches stacks under an evented backend.
- Assume `Io.Threaded` (one thread per concurrent task) is what users actually run on 0.17. Existing third-party Zig HTTP and Postgres libraries were not checked for 0.17 / `std.Io` compatibility **[unverified]**.

## 5. Build-system code generation

### The pattern works in one `zig build` **[ran]**

```zig
const domain = b.createModule(.{ .root_source_file = b.path("src/domain.zig") });

const gen = b.addExecutable(.{ .name = "gen", .root_module = b.createModule(.{
    .root_source_file = b.path("src/gen.zig"),
    .target = b.graph.host,
    .imports = &.{.{ .name = "domain", .module = domain }},
}) });
const run_gen = b.addRunArtifact(gen);
const generated = run_gen.addOutputFileArg2("generated.zig", .{});   // LazyPath

const exe = b.addExecutable(.{ .name = "app", .root_module = b.createModule(.{
    .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize,
    .imports = &.{
        .{ .name = "domain", .module = domain },
        .{ .name = "generated", .module = b.createModule(.{
            .root_source_file = generated,
            .imports = &.{.{ .name = "domain", .module = domain }},
        }) },
    },
}) });
```

- The generator is an ordinary Zig program compiled for the host. It **imports the user's domain module**, so the domain stays declared in Zig (no external schema language). Because the model contains `type` values it is comptime-only: the generator walks it with `inline for` and prints strings (`@typeName(T)`, names) at runtime. The model is still reflected at the generator's compile time; the generator just moves string building and file output to its runtime.
- The output file lands in `.zig-cache/o/<hash>/`; the `LazyPath` returned by `addOutputFileArg2` becomes a module root, and the build graph orders the steps. The generated module can import the domain module and the framework.
- Generated source is ordinary Zig: **types with methods, declarations, doc comments, explicit error sets, readable names** (`generated.User`), all the things comptime generation cannot produce.
- `Run` steps are cached on their inputs (the generator binary and declared file args); the generator must be deterministic and declare any extra inputs with `addFileArg2` / `addDirectoryArg2`.

### 0.17 API changes to the build system

- `addOutputFileArg`, `addFileArg`, `addArtifactArg`, `addDirectoryArg` and their `Prefixed` variants are replaced by `...Arg2(…, options)` with `PathArgOptions{ prefix, suffix, make_absolute }`; the old names remain as deprecated wrappers (`std/Build/Step/Run.zig`; [0.17.0 notes, Build System](https://ziglang.org/download/0.17.0/release-notes.html#Build-System)).
- `b.build_root` → `b.root`; `LazyPath.getDisplayName` → `{f}`; `LazyPath.basename` removed.
- **Configurer / maker split**: `build.zig` now runs in a separate "configurer" process whose result is serialized and cached; the "maker" executes the graph. `build.zig` logic with untracked side effects **poisons the configure cache**; declare inputs with `b.dependOnFileContents` / `dependOnDirectoryContents` instead. There is no overridable "build runner" any more. ([0.17.0 notes](https://ziglang.org/download/0.17.0/release-notes.html#Separate-the-Maker-Process-from-the-Configurer-Process))
  Consequence: do derivation in a **Run step** (make phase), not in `build.zig` logic. `build.zig` itself cannot `@import` the user's domain source in any case, since it is compiled separately.
- Known 0.17.0 regression: the split "breaks response file use cases for `std.Build.Step.Run`" (#36444, [0.17.0 notes](https://ziglang.org/download/0.17.0/release-notes.html#Notable-Regressions)).
- Other generated-file steps: `b.addWriteFiles()` (contents known at configure time), `b.addOptions()` (comptime constants as a module), `b.addUpdateSourceFiles()` (write into the source tree, e.g. to commit generated code or migrations).
- A framework shipped as a package can export a helper function from its `build.zig` that wires the generator into the user's build **[unverified in 0.17: not tested here]**.

### Comptime vs build step, in short

| | Comptime | Build-step codegen |
|---|---|---|
| Methods/decls on derived types | No | Yes |
| Derived error sets | No | Yes |
| Type names in errors | Serialized call expression | Plain names |
| User can read the derived code | No | Yes, in `.zig-cache` (or the source tree) |
| Cost | Every analysis of referencing code | Cached step; plus compiling the generator |
| Setup for the user | `@import` only | Lines in `build.zig` |
| Non-Zig outputs (OpenAPI JSON, SQL migrations) | Only as embedded strings | Natural: write files |
| Editor tooling sees derived types | Depends on ZLS comptime support **[unverified]** | Only after a build has produced the file **[unverified]** |

## 6. Other recent changes that make older knowledge wrong

Language:

- `@Type` removed (0.16); `usingnamespace` removed (0.15); `async`/`await` keywords and `@frameSize` removed (0.15).
- 0.17 removals: `a ** n` (use `@splat`), `void{}` (use `{}`), `errdefer |err|` capture, `i0`. ([0.17.0 notes, Language Changes](https://ziglang.org/download/0.17.0/release-notes.html#Language-Changes))
- 0.17 `@bitCast` redefined: endian-independent, and no longer accepts `extern struct`/`extern union`; array and vector casts may change behaviour silently.
- 0.17 allows `const arr: [3]T = slice.*` and `*const [3]T = slice` for comptime-known-length slices.
- `@cImport` / C translation is moving out of the language into the build system / an external package (0.16, 0.17 notes).
- The language is not yet stable: 0.17.0 reports about 84 undecided language proposals remaining ([0.17.0 notes](https://ziglang.org/download/0.17.0/release-notes.html#Language-Stability-Progress)).

Standard library:

- `std.builtin` → `std.lang`; `OptimizeMode` → `Optimize` with tags `debug`, `safe`, `fast`, `small` (0.17).
- `@import("builtin").cpu/os/abi/object_format` deprecated for `.target.*` (0.17, removal planned in 0.18).
- Containers are unmanaged by default: `std.ArrayList(T)` takes the allocator per call and starts from `.empty` (0.15, 0.16 "Migration to Unmanaged Containers"). 0.17: `getLast`/`getLastOrNull` → `last()`.
- `std.mem.indexOf*` renamed to `find*` (0.16); `std.ascii.indexOfIgnoreCase` → `findIgnoreCase` (0.17).
- `std.fmt.allocPrint(gpa, …)` → `gpa.print(…)` (0.17).
- `std.zon.parse` reworked to take an options struct and an arena (0.17).
- Environment variables and process args are no longer global: they come from `main`'s `init` (0.16).
- `std.fs` file and directory APIs moved under `std.Io.Dir` / `std.Io.File` and take `io` (0.16).
- `std.once` removed; `std.Thread.Pool` removed (0.16).

## Open items not resolved here

- Whether a hard comptime memory cap exists.
- How incremental compilation treats heavy comptime derivation after unrelated edits.
- Status of the stackless-coroutine proposal and when evented networking lands.
- 0.17 readiness of third-party HTTP and Postgres libraries.
- ZLS behaviour with comptime-generated versus build-generated types.
- Changes in 0.17.1.
