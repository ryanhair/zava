# PROTOTYPE, throwaway: relationships as a sibling declaration

Answers the relationship half of *Typing calculation and relationship names in expressions*. Zig 0.17.1.

`relationships` moves out of `resource` into its own declaration with the entries unchanged. Expressions, loads and anything else inside `resource` then read the names without a dependency loop.

Run a case: `printf 'pub const mistake: u8 = N;\n' > cfg.zig && zig run --dep zava --dep domain -Mroot=main.zig -Mzava=zava.zig --dep zava --dep cfg -Mdomain=domain.zig -Mcfg=cfg.zig`. All results in `errors.txt`.

| N | Case | Result |
| --- | --- | --- |
| 0 | correct: mutual relationships, a to-one then a to-many of the far side, a resource with no declaration | compiles and runs |
| 1 | misspelled relationship in an existence test | compiler error on the token |
| 2 | misspelled attribute on the far side | compiler error on the token |
| 3 | far-side literal of the wrong type | compiler error on the token |
| 4 | existence test over a to-one | framework error, developer's line in a note |
| 5 | misspelled relationship in a load | compiler error on the token |
| 6 | misspelled attribute in a relationship entry | compiler error on the token |
| 7 | empty `relationships`, relationship used | compiler error on the token |
| 8 | declaration named `relationship` | framework error from a near-miss check by name |

Also shown: `@hasDecl` is false for a declaration not marked `pub` seen from another module, so a private `relationships` is not seen.

Not exercised: ZLS, many-to-many and the join resource, related writes, calculation bodies.
