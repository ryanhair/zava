# PROTOTYPE: typing argument names in expressions (throwaway, never merged)

Answers the ticket *Typing argument names in expressions*: can the name of an argument inside an expression be a compiler error on the exact token, and what does an action entry look like if it can? Zig 0.17.1.

Run: `zig run main.zig` (output in `output.txt`). Mistakes: `python3 errors.py` (output in `errors.txt`).
Probes for calculation and relationship names: `zig run probe_split.zig`, `zig run probe_types.zig`; mistakes: `python3 probe_errors.py` (output in `probe_errors.txt`).

## What was built

The same read action, `popular`, in three shapes (`domain.zig`). All three lower to the same action and the same node list (`output.txt`).

- **Shape 0, current.** Arguments are a list of entries; `.arg` takes any name.

  ```zig
  .{
      .name = "popular_0",
      .arguments = &.{.{ .name = "min_views", .type = i64, .min = 0 }},
      .filter = .all(&.{ .eq(.status, .value(.published)), .gt(.views, .arg(.min_views)) }),
  },
  ```

- **Shape 1, the action is a function call.** The arguments are a struct type passed as a parameter, so the type of everything after it carries them. Options an argument adds to its type go in a block keyed by argument name.

  ```zig
  .read("popular_1", struct { min_views: i64 }, .{
      .arguments = .{ .min_views = .{ .min = 0 } },
      .filter = .all(&.{ .eq(.status, .value(.published)), .gt(.views, .arg(.min_views)) }),
  }),
  ```

- **Shape 2, the arguments type is named at the argument.** The entry stays a literal; the arguments are a named struct written outside the declaration, and the expression names it, as a destination is named when a relationship is crossed (ADR 0006).

  ```zig
  pub const PopularArguments = struct { min_views: i64 };
  ...
  .{
      .name = "popular_2",
      .args = PopularArguments,
      .filter = .all(&.{ .eq(.status, .value(.published)), .gt(.views, .argOf(PopularArguments, .min_views)) }),
  },
  ```

## Findings: arguments

| Mistake | Shape 0 | Shape 1 | Shape 2 |
| --- | --- | --- | --- |
| Argument that does not exist | checker, when the model is lowered; no location in the developer's file | compiler error on the token | compiler error on the token |
| Argument of the wrong type | checker, as above | compiler error on the token, worded as "no member named" | framework error with a clear message; the developer's token is the third location, in a note |
| Another action's arguments named | cannot happen | cannot happen | checker, when the model is lowered |

1. **Yes, it can be typed.** In shape 1 a misspelled argument is `domain.zig:34:39: error: enum 'zava.ArgName(domain.Post.resource__struct_856,i64)' has no member named 'min_view'`, with the caret on the name.
2. **The wrong type can land on the token too**, by making the accepted names an enum of only the arguments whose type fits. The cost is the wording: an argument that exists but has the wrong type is reported as "no member named 'min_views'", and the enum's name is the only hint (`...,[]const u8)`). The other choice (shape 2 here) accepts every argument name and checks the type itself: a clear message, but reported from framework code with the developer's line in a note. Either choice works in either shape.
3. **Nothing else gets worse in shape 1.** A missing attribute and a misspelled entry field are still compiler errors on the token (controls 4 and 5). The body's type name in errors is `zava.ReadBody(domain.Post,domain.Post.resource__struct_856)`: the anonymous arguments struct has an unreadable name. Naming the struct fixes the name and costs a declaration outside the entry.
4. **Shape 1 changes more than the argument list.** The action name becomes a positional string, the action kind becomes the function (`.read`, `.create`, ...), and argument options move to a keyed block, because a struct field can carry a type and a default but nothing else. That block is typed: an option that does not exist and options for an argument that does not exist are compiler errors on the token (mistakes 6 and 7). The action then has the same form as the resource: a struct plus a keyed options block.
5. **Shape 1 reaches every expression in the action**, since the whole body is typed on the arguments: filter, atomic update, step conditions. Other places that name an argument (a related write's `.argument`, an extension step, ADR 0013 and 0014) could be typed the same way. Not built.
6. **Shape 2 keeps the entry as it is** and pays elsewhere: the arguments struct lives outside the declaration under a name the developer invents, that name is repeated at every argument, and naming another action's arguments type is caught only by the checker.
7. **An argument type that cannot appear in an expression** (`f32` here) is reported from framework code in shape 0, and in shape 1 as "no member named" at the first use, which misleads. Shape 1 would need its own check on the arguments struct.

## Findings: calculation and relationship names

The cause is the same (the names are part of the declaration the expression is written inside), and so is the cure: the names must be readable without reading the value of `resource`. Two ways were probed.

- **Split** (`probe_split.zig`): `relationships` and `calculations` become their own declarations beside `resource`. Relationship names and calculation names are then compiler errors on the token, a calculation at the wrong type too, and the destination no longer has to be named (`.exists(.comments, ...)`), with the far side still typed. **But a calculation cannot read another calculation**: `dependency loop with length 2`. ADR 0010 allows that, so split alone does not carry calculations.
- **Types** (`probe_types.zig`): the same move as shape 1. The names and types are struct types beside the record (`pub const Calculated = struct { popularity: i64, hot: bool };`, `pub const Related = struct { comments: Many(Comment) };`); `resource` keeps bodies and options in blocks keyed by name. Everything is typed on the token, a calculation may read a calculation, mutual relationships work, the destination is not named, and a declared calculation with no body or a body with no declaration is a compiler error on the token. Cost: each calculation name is written twice (type, then body), and the record gains two sibling type declarations by fixed names.

So the move reaches both, and for relationships it also removes the destination naming that ADR 0006 accepted. It is a larger change to the declaration than the argument question: it moves two of the declaration's lists out of `resource`.

## Not exercised

ZLS behaviour on any of the shapes, compile cost, optional arguments and defaults (a struct field default would carry the default), accepted attributes next to arguments in the input, generated input types (ADR 0003: with shapes 1 and 2 the arguments struct is developer-written source), write actions and steps, hoisting a shape 1 entry into a constant, relationship options and the join resource in the types probe.
