# A built-in step is carried to the data layer; no step takes a condition

The kernel has four built-in steps: an assignment, a precondition, a generated UUID and the related write (ADR 0013). The two that hold an expression are never run by the kernel. An assignment sets one attribute to the value of an expression, and a precondition is a filter the stored record must satisfy; both ride inside the one operation the kernel hands the data layer (ADR 0005), which evaluates them as part of the write. No step, built-in or function, takes a condition. We chose this because the data layer is the only thing that ever gives an expression a value (ADR 0010): a step the kernel ran itself would need a second implementation of the expression language, and a step carried in the operation costs no read, keeps the action one statement, and applies to a set of records exactly as written.

```zig
.before = &.{
    .{ .precondition = .{ .that = .eq(.state, .value(.pending)), .code = "not_pending" } },
    .set(.state, .value(.approved)),
    .set(.approved_by, .ctx(.{ .actor, .id })),
    .set(.approved_at, .now),
    .set(.revision, .add(.revision, .value(1))),
},
```

The spelling is illustrative. `set` is a constructor typed like a comparison with an attribute on the left (ADR 0006), so a value of the wrong type is a compiler error on the token.

## The catalogue

- **Assignment** (`set`): attribute and expression. Before phase of a create or an update.
- **Precondition**: a filter, a code, and optionally a path and a message. Before phase of an update or a destroy.
- **Generated UUID** (`generate`): a `Uuid` attribute and a version, 7 by default, 4 on request. Before phase of a create.
- **Related write**: as ADR 0013. After phase of a create or an update.

There is no built-in step in the after-commit phase, on a read action or on a generic action; those take function steps only.

## Considered Options

- **A small evaluator in the kernel** for a subset of expressions (copies of an operand, equality, integer comparison): assigned values would be in the draft and failures would accumulate with the others. Rejected because it is the second implementation ADR 0010 rejected, and the edge of the subset would have to be explained for ever.
- **Reading the current record, with a lock, and evaluating in the program**: rejected because it needs that evaluator and a read on every call, and cannot be lifted to a set.
- **Built-in validations over the input alone** (`end > start`, a confirmation that equals a password, at least one of two arguments), either as an in-memory catalogue or sent to the data layer: rejected. A rule about one value is a constraint (ADR 0007). A rule across values is a function validation: a few lines of Zig typed by the compiler, which runs in memory, accumulates, and stays in the function derived for validating without executing. No derivation could use such a rule if it were data.
- **A condition on a step** (Ash's `where:`): rejected. A condition is an expression, so only the data layer could evaluate it, and it would say nothing an expression cannot already say: a conditional assignment is `cond`, a conditional precondition is `any` of the negated test and the filter, and a conditional function step is an `if` inside the function.
- **A precondition failing as rejected or conflict**: rejected. A validation fails as invalid wherever it is evaluated; rejected belongs to changes and after steps, and conflict means other records refused the write (ADR 0009).
- **Generating a UUID in the data layer**, as an operand of the expression language: rejected because a new primary key is wanted in the draft before the write, and because it would tie the default to one Postgres version.
- **A node that reads the supplied value of an accepted attribute**: rejected for now. Accepting an attribute means its input goes to the attribute unchanged; a value that takes part in an expression is declared as an argument and assigned. The node is reserved.

## Consequences

- A change is no longer always a mutation of the draft. A function change and a generated UUID put a value in the draft; an assignment does not, so a function step cannot read an assigned value and the draft has no field for it. A function step that needs the same value reads the argument or the context itself.
- Inside an assignment or a precondition, a reference to an attribute or calculation reads the stored record as it was before the write. On a create there is no stored record, so such a reference is a compile error, as is a precondition on a create and an assignment on a destroy. A precondition that reads nothing from the stored record is a compile error that says to write a function validation.
- An expression in a step may read arguments, the context, literal values, `now`, and related records through the nodes of ADR 0006. It cannot read an accepted attribute's supplied value.
- Each attribute has one source per action. An attribute set by an assignment may not be accepted, set by a function change, generated, or assigned twice in that action: each is a compile error. Assignments therefore do not depend on each other, and the position of an assignment or a precondition in the before list has no effect on what it does. They stay in the list so that the entry shows the whole pipeline and an extension step can expand to them in place (ADR 0014).
- A generated UUID is made by the kernel in the program, from the clock and the randomness of the scope's `std.Io`, at its position in the list, and lands in the draft. It is skipped when the attribute is accepted and the caller supplied it. Version 7 is the default so that primary key order, the order of a read with no sort (ADR 0011), is roughly creation order; version 4 is for an identifier that must not reveal when it was made.
- The kind of an assignment's expression must match the attribute's, and an optional result cannot be assigned to an attribute that is not optional. When the expression is a single operand whose value the kernel holds, the attribute's constraints are checked: a literal at build time, an argument or a context field before the write, as a value a change set (ADR 0009). A computed value is not checked against constraints, as with a calculation's stated type (ADR 0010); a result out of range is raised by the data layer (ADR 0015).
- The current time is `.set(.created_at, .now)`: the data layer's clock at the statement, the one meaning `now` has everywhere. The kernel has no timestamp option on an attribute; an update that maintains one lists the assignment, hoisted into a constant when shared. Doing it for every action of a resource is an extension's implicit step (ADR 0014).
- The data layer's update and destroy operations carry the preconditions beside the primary key. The data layer must report a missing record apart from a failed precondition, and must report every precondition that failed, not only the first. Not found wins when the record is missing. How it does this in one statement is its own business.
- A failed precondition is the failure kind invalid, one entry each: the developer's code, which is required, an optional path naming a member of the input (checked when the model is lowered, like an argument name), an empty path otherwise, and an optional message. Preconditions add no code to the kernel's closed list.
- Preconditions are known to have failed only at the data layer. Constraints and function validations fail first and stop the action before it; preconditions are reported together, and only when those passed.
- A precondition is not part of the function derived for validating without executing, since it needs the stored record. A related write's before-phase check therefore does not cover the destination action's preconditions: one that fails does so during that element's call and rolls the whole call back (ADR 0013).
- A related write takes no condition. It makes no calls when its argument is omitted or empty, and its before-phase check always runs.
- Neither an assignment nor a precondition makes the kernel read the current record. An action built from them is one statement, and both are recorded in the model as liftable to a set, as is a generated UUID. The model records each built-in step as plain data: its kind and its fields, the expression included. An extension step that expands to these is liftable (ADR 0014), which covers a check on the stored record's value, an attribute set from the context and an attribute set from an expression.
- An assignment that reads the stored record (`.add(.views, .arg(.by))`) is an atomic update. That feature was reserved; it is now part of the design, at no further cost.
- An optimistic lock is a precondition on a version attribute plus an assignment that increments it, and fails as invalid with the developer's code.
- Not provided, and reserved: an assignment applied only when the caller did not supply the attribute, a node that reads an accepted attribute's supplied value, and what a failed precondition means for one record among a set, which is decided with bulk actions.
- Amended (policies, ADR 0017). The update and destroy operations also carry the action's filter policies as named filters, and the data layer reports each one that refused, apart from a missing record and from failed preconditions. A missing record wins over a refusal, and a refusal wins over failed preconditions, so preconditions are reported only for a record the caller may write.
