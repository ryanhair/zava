# Comptime versus generation boundary: probes

Throwaway, never merged. Three small probes on Zig 0.17.0 run while resolving the "Comptime versus code generation boundary" ticket.

1. `1-typed-comptime-surface`: a comptime-only call surface (`run(comptime R, comptime action: ActionName(R), input: Input(R, action))`) needs no `anytype`, and its mistakes are compiler errors on the caller's token. `zig run probe.zig`.
2. `2-hook-calls-generated-source`: a function in the domain module whose body calls generated source builds in one `zig build run`, provided the declaration names it by declaration name. Holding it as a function value fails, because the build step must then analyse the body before the generated source exists.
3. `3-types-source-behaviour-comptime`: the adopted split. Input types and action signatures are generated source; behaviour (`zava.run`) and derived values (`zava.sql`) are comptime, typed on the generated types by lookup; derived SQL is printed into doc comments. `zig build run`, then `zig build` to write `zig-out/api.zig`.
