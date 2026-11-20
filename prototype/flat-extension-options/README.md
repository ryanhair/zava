# PROTOTYPE, throwaway: extension options at the declaration root

One file. `Options(R)` is built with `@Struct` from the kernel's hand-written fields plus one optional field per registered extension.

Run a case (Zig 0.17.1): `printf 'pub const mistake: u8 = N;\n' > cfg.zig && zig run --dep cfg -Mroot=probe.zig -Mcfg=cfg.zig`

| N | Case | Result |
| --- | --- | --- |
| 0 | correct | compiles and runs |
| 1 | misspelled kernel option | `no field named 'primry_key' in struct 'probe.Options(probe.Author)'`, on the token |
| 2 | misspelled extension name | `no field named 'postgre' in struct ...`, on the token |
| 3 | misspelled attribute in an action | `enum 'meta.FieldEnum(probe.Author)' has no member named 'emial'`, on the token |
| 4 | extension named after a kernel option | framework compile error naming the extension |
| 5 | required kernel option missing | `missing struct field: primary_key`, on the literal |

The "struct declared here" note points at the `@Struct` call in the framework, not at a readable list of fields. Editor behaviour was not measured.
