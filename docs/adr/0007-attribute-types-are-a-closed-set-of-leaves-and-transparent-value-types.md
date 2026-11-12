# Attribute types are a closed set: kernel leaves and transparent value types

The kernel fixes the set of types an attribute, argument or calculation result may have, and every extension must map each of them or raise a compile error. The set is made of plain Zig shapes, a closed list of built-in types shipped by the kernel, and value types: developer-written structs whose own fields are their storage. Nothing converts between a type and a stored form. We chose this because it gives "is this a legal attribute" one answer for the whole build, keeps values that mean different things from sharing a Zig type, and puts no allocation or conversion between a record and the data layer.

## The set

- **Plain shapes**: `bool`; signed and unsigned integers up to 64 bits; `f32` and `f64`; `[]const u8`, always meaning text; a developer-written `enum`; `?T` of an accepted type, meaning nullable; `[]const T` of an accepted type, meaning a list; a plain struct whose fields are all accepted types, meaning a composite.
- **Built-in types**: `zava.Uuid` (16 bytes), `zava.Instant` (`i64` microseconds since the Unix epoch, UTC), `zava.Date` (`i32` days since the epoch), `zava.Decimal` (`i128` unscaled value and a `u8` scale, 38 digits, no allocation), `zava.Bytes` (wraps `[]const u8`).
- **Value types**: a struct with a `pub const zava_type = zava.Type(@This()){ ... }` declaration. One field (`Email { value: []const u8 }`) is stored and exposed as that field's shape; several fields (`Money { amount: Decimal, currency: Currency }`) are a composite.

Excluded: pointers, arrays, error unions, unions of either kind, `usize`, integers over 64 bits, and `??T`. Time of day, interval, timestamp without zone and arbitrary JSON are not built-in types yet; each is addable as a new leaf.

## Considered Options

- **Open set** (the kernel accepts any Zig type and each extension rejects what it cannot map): rejected because whether a field is an attribute would have a different answer per extension, and no answer at all for a resource with no data layer.
- **Retagged primitives** (`id: [16]u8` with `.id = .{ .type = .uuid }` in the options block): rejected because an `i64` timestamp and an `i64` count stay interchangeable to the compiler, and the type is stated twice. This is not the wrapper field type that ADR 0001 rejected: a built-in or value type is the value's real type, the same wherever it is used, and carries no per-field options.
- **One mechanism with conversion functions** (every named type, kernel or developer, states a storage shape and a pair of functions to and from it, so the kernel has no privileged types): rejected because a UUID stored as text needs a buffer on every read and write, every conversion raises the question of who owns the result, and an extension that did not know the type would silently store its fallback form. The cost of the choice made instead is that the kernel has privileged types and a developer cannot add a leaf.
- **Constraints only in the per-attribute options block** (the field stays `[]const u8` and "email" exists only as options): rejected because the constraint would be restated at every use and an unchecked string could be passed where an email is expected.

## Consequences

- An extension maps every plain shape and every built-in type. It maps a value type by its fields unless told otherwise. A data layer may reject what it cannot hold (a `u64` in Postgres, a list of lists) with its own error naming the resource and attribute.
- A value type's declaration follows the resource pattern: an `extensions` block keyed by registered extension name, typed by an optional per-type options type that the extension contract gains (ADR 0004 amended). That is how a type the data layer has natively but the kernel lacks is reached: a one-field text type with `.postgres = .{ .type = "inet" }`.
- A one-field value type is transparent everywhere outside the program: `Email` is a JSON string, not an object. Inside the program the record field is read as `author.email.value`.
- A plain nested struct needs no declaration. It becomes a value type when it wants constraints, a validate function, a sensitive flag or extension options.
- A value type's fields may be any accepted type, including other value types. Tagged unions wait until a derivation needs them, as in descriptions (ADR 0004).
- Constraints are data: `min_length` and `max_length` on text and lists, `min` and `max` on numbers. They are written on a value type's declaration and in the per-attribute options block; both apply, each checked on its own, and a pair that no value can satisfy is a compile error naming the resource and attribute. There is no pattern constraint, since the standard library has no regular expressions.
- A value type may name one validate function for what constraints cannot say. Derivations cannot read it; they read constraints.
- Constraints and validate functions run on arguments and accepted attributes when input arrives, before any step, and on any attribute a change set, before the write. They never run on records read from the data layer.
- A struct field default is the attribute's default on create when input does not supply it. Computed defaults (the current time, a new UUID) are changes.
- An enum is its tag name everywhere outside the program by default. Native enum types and integer storage are data-layer options.
- The per-attribute options block carries `public` and `sensitive`, both false by default (ADR 0001 amended). An API surface exposes only public attributes, so a forgotten flag hides data and never leaks it. Sensitive is a model fact: the kernel redacts the value in its own failure detail and in any debug formatting it derives, and extensions decide the rest. The two flags are independent. A value type may declare itself sensitive, which makes every attribute of that type sensitive; public is never stated on a type.
- The kernel rejects nullable attributes, floats, lists and composites in a primary key or identity. Any further restriction is the data layer's.
- Embedded resources (a resource used as an attribute value) are not settled by this decision. A composite covers nested data without actions or policies of its own.
