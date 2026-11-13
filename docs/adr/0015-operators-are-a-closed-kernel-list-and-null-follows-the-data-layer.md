# Expression operators are a closed kernel list with data-layer additions, and null follows the data layer

The kernel fixes the list of operators an expression may call, and every data layer must lower all of them. Only a data layer may add operators beyond that list. A null operand behaves as it does in SQL: a comparison with a null operand has no result, and a filter does not select a record for which it has no result. We chose this because the data layer is the only thing that ever gives an expression a value (ADR 0010): a kernel list means an expression is portable across data layers by default, and any null rule other than the data layer's own would be a promise the kernel has no evaluator to keep.

## The operators

- **Comparison**: `eq`, `ne`, `lt`, `le`, `gt`, `ge`.
- **Logic**: `all`, `any`, `not`. `all` of nothing is true and `any` of nothing is false.
- **Null**: `is_null`, legal only on an optional operand, and `or_else(x, fallback)`, which removes optionality.
- **Membership**: `in(x, list)`, where the list is a value, an argument or a list attribute. Membership in an empty list is false.
- **Arithmetic**: `add`, `sub`, `mul`, `div`, `neg`.
- **Text**: `contains`, `starts_with`, `ends_with`, their case-insensitive forms `icontains`, `istarts_with`, `iends_with`, and `concat`, `lower`, `upper`, `length`.
- **List**: `length`.
- **Conditional**: `cond(test, then, otherwise)`. Both branches have the same kind, and the result is optional if either branch is.
- **Operand `now`**: the time of the statement, an `Instant`.

Not provided: modulo, rounding, regular expressions, wildcard patterns, parts of a date, and arithmetic on instants and dates (the set of attribute types has no interval, ADR 0007; the caller computes a cutoff and passes it as a value or an argument).

## Considered Options

- **Forbidding a comparison on an optional operand unless null is handled explicitly**: every such comparison would then have a result. Rejected because nearly every filter on an optional attribute would need wrapping, for a guarantee that only matters under `not`.
- **Null equals null** (`IS NOT DISTINCT FROM` for `eq`): rejected because it gives `eq` a second meaning that differs from every other comparison and cannot use an ordinary index.
- **An open list** (any extension declares operators): rejected because only a data layer can lower one, so an operator from anything else would have no meaning.
- **A cast operator and free mixing of numeric types**: rejected in favour of a small promotion rule, below; a cast is addable later.

## Consequences

- The checker tracks whether a result is optional. A filter accepts an optional boolean. The stated type of a calculation must match the optionality of its body (ADR 0010).
- The literal in a comparison with an optional attribute has the attribute's non-optional type, so `.eq(.deleted_at, .value(null))` is a compiler error on the token. `is_null` is the only way to test for null.
- The checker works in kinds, which are coarser than Zig types: integer, float, decimal, text, boolean, an enum, UUID, instant, date, bytes, a list of a kind, and a composite. Integers of any width mix; an integer is promoted to a decimal when the other operand is a decimal; a float mixes with nothing. `div` on two integers is integer division.
- `lt`, `le`, `gt` and `ge` are legal on integer, float, decimal, text, instant, date and UUID. Boolean, bytes, enum, composite and list operands take `eq`, `ne` and `in` only, and a composite is compared field by field. An enum is not ordered because its order would be alphabetical under one storage option and declaration order under another (ADR 0007). A sort term obeys the same table (ADR 0011 amended).
- A one-field value type is its own type to the compiler, so a literal compared with an `Email` attribute must be an `Email`, and its field's kind to the checker, so text operators apply to it. A field of a composite is reached by a path. A list attribute takes `in` and `length` only.
- The kernel fixes the meaning of text operators this far and no further: `eq`, `ne`, `contains`, `starts_with` and `ends_with` are exact; the case-insensitive forms, `lower` and `upper` fold case by the data layer's rule; the order of text is the data layer's collation, which the data layer documents. The text searched for is always literal: the lowering escapes pattern characters, so no wildcard reaches a statement from a value.
- Division by zero and a result out of range are raised by the data layer while a statement runs. Both are the failure kind invalid (ADR 0009), with the codes `division_by_zero` and `out_of_range`, an empty path, and the action, and the calculation when known, as origin. A literal zero divisor is a compile error.
- A data layer declares each operator it adds as data: a name, the kinds of its operands and the kind of its result. The checker types a call from that data and the data layer lowers it. The call node identifies an operator as either a kernel operator or an extension and a name. The developer writes it through the data layer's own constructors, which produce the same nodes. A resource whose expressions use such an operator is bound to that data layer, and lowering it with another is a compile error.
- A request filter may name public attributes and public expression calculations that are not sensitive, the same rule as a request sort (ADR 0011), since a filter on a sensitive value reveals it one question at a time. Every such name is filterable by default and the API surface has a per-action option to narrow the list. A request filter may use every kernel operator. It may not cross a relationship, read the context or an argument, or use a data-layer operator unless the API surface allows that per action. It is combined with the action's declared filter by `all`.
- Crossing a relationship from a request filter, arithmetic on instants and dates, and operators from an extension that is not a data layer are reserved.
