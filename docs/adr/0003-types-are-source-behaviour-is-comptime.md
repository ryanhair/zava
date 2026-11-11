# Types are source, behaviour is comptime

Every type and signature a developer writes code against exists as plain Zig source: records are written by the developer, and the rest (action inputs, the functions that run actions) is generated source, written by one emitter in the kernel during the same `zig build`. Behaviour and derived values (SQL, request handling, validation, routing) are produced by comptime code, which is typed on those source-written types and never builds a type with `@Struct` or `@Enum`. Extensions are comptime only: they never write source text, and when one needs a developer-facing type it returns a description of it as data, which the kernel emitter writes out. This replaces the earlier bet that everything is derived in comptime, with generation as a rare exception.

The split follows a measurement. ZLS 0.17.0 has no comptime interpreter and resolves every `@Struct` and `@Enum` type to an unknown type, so derived inputs and action names get no completion, hover types or go-to-definition, and no reshaping of the comptime code fixes that. An editor needs types to exist as text; it does not care how behaviour is produced. Extension authors, who do most of the work in this framework, produce behaviour far more often than types, and are best served by ordinary type-checked comptime Zig.

## Considered Options

- **Comptime only**: one mechanism and no build phase. Rejected because the editor goes blind on exactly the types developers touch most, and the fix depends on compiler work with no date (ziglang/zig#615).
- **Generate everything** (comptime only types the declaration, lowers and validates; all derived code is emitted as readable source): the best experience for the developer, who can read and step through spelled-out code. Rejected because every extension would have to write source text: mistakes surface in the developer's build rather than the extension's, extensions couple through generated names instead of types, and a source-writing library becomes a feature of its own. Extensions are the core of the project, so their authors come first here.
- **Comptime-derived types behind a generated facade**: restores the editor but leaves two vocabularies of types for the same things. Rejected in favour of making the generated types the only ones.
- **Developer-written input structs checked at comptime**: makes the types visible, but calls through a generic function still get no completion, and the developer types more.

## Consequences

- Go-to-definition on an action lands on a generated signature with documentation, and one step further lands in generic comptime code rather than spelled-out steps. The emitter prints derived values, such as an action's SQL, into doc comments to compensate.
- A declaration refers to a developer-written function by its declaration name, never by function value. Holding the value forces the build step to analyse a body that may use generated source that does not exist yet; naming it lets the domain module and the generated source import each other. A misspelled name is still a compiler error on the exact token.
- Comptime code reaches a generated type by looking it up by name. An extension cannot invent a developer-facing type on its own; it describes one and the kernel writes it.
- The domain module must compile for the host machine, because the build step imports it.
- Validation stays in comptime lowering, at the domain root, so model errors arrive as compiler errors and reach the editor as diagnostics. The compiler stops at the first one.
- Generated source is a module in the build graph and lives in the build cache. The program cannot compile against stale output, and nothing generated is committed. It is not readable on a code host, and go-to-definition opens a cache path.
- Derivations run in the main build by default, including files nothing compiles, such as an OpenAPI description, which are comptime-derived values the build writes out. One gets its own build step only if it is slow and the build does not need it.
- Nothing is discovered or decided at runtime, as before: the closed world and the absence of runtime reflection are unchanged.
- Completion while writing a declaration is not improved by any of this, since the declaration is the input to generation.
