# PROTOTYPE: expression language (throwaway, never merged)

Answers the ticket *Expression language*: what is an expression, and how is one written, typed and lowered? Zig 0.17.1.

Run: `zig run main.zig` (output in `output.txt`). Mistakes: `python3 errors.py` (output in `errors.txt`).

## What was built

- **One representation** (`zava.zig`, top): an expression is a list of nodes in prefix order (`all/2 eq/2 status 'published' gt/2 views $min_views`). Plain data, no types and no pointers between nodes. Six node kinds: a reference to an attribute or calculation, an argument, a value, a call of an operator, `exists` over a to-many relationship, and a read through a to-one relationship.
- **One checker** (`check`): walks the list against the model and returns the result kind or a message. The build runs it on every declared expression; the same function runs at runtime on an expression built from a request.
- **One lowering** (`lowerAt`, the data layer's job): writes parameterised SQL. For a declared expression the statement text is a comptime constant; for a runtime expression the same function writes it at runtime. No value ever enters the text.
- **Three spellings** of the same filter, all producing the identical node list and SQL (`domain.zig`):
  - **A, prefix**: `.all(&.{ .eq(.status, .value(.published)), .gt(.views, .arg(.min_views)) })`
  - **B, method**: `p.attr(.status).eq(.value(.published)).andAlso(p.attr(.views).gt(.arg(.min_views)))`
  - **C, string**: `.parse("status == 'published' and views > $min_views")`, parsed at comptime
- The four uses the ticket names: declared in a resource, written at a call site with a runtime value, built from a request (`views.gt=10&status.eq=published`), lowered to SQL. Plus the three constraints: a calculation body and a calculation inside a filter (inlined), an atomic update (`set views = (t0.views + $1)`), and both relationship directions.

## Findings

1. **The representation carries all four uses.** The checker and the lowering are ordinary functions with no comptime-only construct, so each runs unchanged at build time and at runtime. Typing does not need Zig types in the tree.
2. **A and B are typed by the compiler on the exact token** for a missing attribute, a literal of the wrong type, a missing enum value, and a missing attribute on the far side of a relationship; this holds at a call site with runtime values too. They are the same Zig type (`Term(R, V)`), so they mix freely.
3. **An attribute of the wrong type** (`.gt(.views, .attr(.title))`) is a framework `@compileError` with a good message, and the developer's token is the third location, in a note.
4. **Three things cannot be typed at the token in any spelling**, and fall to the checker when the model is lowered: argument names, calculation names, relationship names. The error names resource, action and the mistake, but points at framework code and the `zava.model(...)` line, not the developer's line. Cause: they are part of the declaration the expression is written inside; reading it from there is a dependency loop (`probe_relationship_typed_in_declaration.txt`). Outside the declaration (a call site) relationship names could be typed.
5. **Because of 4, A and B name the destination type when crossing a relationship** (`.exists(Comment, .comments, ...)`). Naming the wrong destination is caught only if an attribute name or type differs.
6. **C is typed by nothing until the checker runs.** Every mistake is reported from framework code with the message carrying the location in words. A misspelled enum value was not caught at all here (enums are text in this prototype; the attribute types ticket decides). A syntax error reports an offset into the string. C reads best and is the only spelling where a calculation, a relationship and an attribute look alike.
7. **B needs a handle** (`const p = zava.of(@This());`), cannot use `and`/`or` as method names (keywords), has no operator precedence, and falls back to A's constructors for `not`, `exists` and relationship reads. It is the longest of the three once an expression leaves the two-comparison case.
8. **A has two comparison forms**: `.gt(.views, rhs)` when the left side is an attribute (rhs typed from the attribute), and `.cmp(i64, .gt, lhs, rhs)` with the type stated when it is not. The compiler cannot infer the type of a left operand written as a decl literal.
9. **Pointer-free matters for call sites.** A tree of pointers built by functions at runtime would point at dead stack frames; it would need an allocator or a second builder. The prefix list is built by value on the stack. Cost: a fixed capacity (32 nodes here, about 1 KB per term), a panic at runtime and a compile error at comptime when exceeded.
10. **A request filter is checked twice over**: the value is parsed by the attribute's kind (`views.gt=ten` rejected), then the whole expression goes through the same checker as the build (`featured.gt=true` rejected).

## Not exercised

Null and optional attributes, `in`, text functions, sort and pagination, aggregates, a reference from inside `exists` back to the outer record, the context as an operand, policies, public/sensitive flags on request filters, a real Postgres round trip, ZLS behaviour, compile cost.

## Follow-up: relationship crossing with and without the destination named

`trending_a` names the destination (`.exists(Comment, .comments, ...)`); `trending_loose` does not (`.existsLoose(.comments, ...)`, inner term is the untyped `Loose`). Same node list, same SQL. Mistakes both ways in `errors_relationship.txt`.

- Named: a missing far attribute and a far literal of the wrong type are compiler errors on the exact token. Not named: both are checker errors pointing at framework code, naming resource and action.
- A missing relationship is a checker error both ways.
- Naming the wrong destination never produces wrong SQL: the checker and the lowering use the relationship's real destination from the model. It compiles silently when the attribute exists on both with the same type, and otherwise gives a checker error about the real destination. The node does not record the named type, so the mismatch itself is not reported; recording it would let the checker say so.
- The branch quota is per comptime entry point: adding one action pushed `main.zig`'s comptime statement derivation past 1000 until it raised the quota itself.
