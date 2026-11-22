# PROTOTYPE, throwaway: policies as a sibling declaration

Answers one part of *Authorization policy model*: whether a `policies` declaration beside `resource` gets its action names typed on the token. Zig 0.17.1. Built on the `prototype/relationship-typing` prototype.

`policies` is its own declaration, `pub const policies: []const zava.Policy(@This()) = &.{ ... };`. Its type reads the action names from `resource`, and `resource` reads nothing from `policies`, so there is no dependency loop.

Run a case: `printf 'pub const mistake: u8 = N;\n' > cfg.zig && zig run --dep zava --dep domain -Mroot=main.zig -Mzava=zava.zig --dep zava --dep cfg -Mdomain=domain.zig -Mcfg=cfg.zig`. All results in `errors.txt`.

| N | Case | Result |
| --- | --- | --- |
| 0 | correct: three policies on a resource with mutual relationships, a resource with no declaration | compiles and runs |
| 11 | misspelled action name in a policy | compiler error on the token |
| 12 | misspelled attribute in a policy's filter | compiler error on the token |
| 13 | misspelled relationship in a policy's filter | compiler error on the token |
| 14 | misspelled function name | compiler error on the token |
| 15 | misspelled action kind | compiler error on the token |

Not exercised: ZLS, argument and calculation names in a policy's filter, the near-miss check on the declaration's name, a policy function's signature.
