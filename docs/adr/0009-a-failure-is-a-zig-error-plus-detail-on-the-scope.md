# A failure is a Zig error plus detail on the scope

An action call that does not complete returns an ordinary Zig error, one per failure kind, and writes the detail to a single slot on the scope, `scope.failure`. There are six failure kinds and the list is closed: invalid, forbidden, not found, conflict, rejected and unavailable. Every action and every function step returns the same error set, `zava.Error`, which is those six plus `OutOfMemory` and `Canceled`. We chose this because Zig errors carry no payload, the scope already travels with every call and step (ADR 0008), and an error is what makes `try` and `errdefer` work: a nested action's failure propagates through a step with no code, and rollback hangs on the error path.

```zig
const author = Author.register(scope, context, input) catch |err| switch (err) {
    error.Invalid => return render(scope.failure.?),
    else => |e| return e,
};
```

## Considered Options

- **A result union** (`union(enum) { ok: Author, failed: Failure }`): rejected because it ties detail to the outcome in the type at the price of `try`. Every nested call inside a step would need a `switch`, and rollback could not use `errdefer`.
- **A separate diagnostics parameter** on every call and step: rejected because it is a fourth parameter for something the scope can carry.
- **An error set per action**, derived from its step list (a read could not return `Conflict`): rejected for now because every generated signature would differ and adding a step would break callers' `switch` statements. It stays addable, since narrowing an error set breaks no caller.
- **Open failure kinds**, added by extensions or developers: rejected because a closed list is what lets every API surface map every failure. Extensions and developers fill the kernel's kinds.
- **Conflict folded into invalid** (Ash reports a violated identity as a field error): rejected because a conflict is found by the data layer after validations have passed and stops the action at once, where validation failures accumulate. An API surface may still render the two alike.
- **The offending value in the detail**: rejected. The caller already has its input, and leaving values out makes the redaction of sensitive attributes hold by construction.

## Consequences

- The six kinds and what each carries:
  - **Invalid**: input broke a constraint or a validation. The only kind that carries a list of entries.
  - **Forbidden**: authorization refused. Carries nothing for the caller.
  - **Not found**: update or destroy of a missing primary key. Carries the resource, not the key.
  - **Conflict**: the data layer refused the write because of existing records. Carries the name of the violated identity, or the name of the relationship and which way it failed: destination missing, or still referenced.
  - **Rejected**: a change, an after step or a generic action refused for a domain reason. Carries a developer-supplied code and an optional message.
  - **Unavailable**: the data layer could not do its job. Carries one opaque text for logs, which no API surface shows.
- Every failure records its origin: the resource and action where it arose. The kernel never rewrites or wraps a nested action's failure; a step that wants to translate one catches the error and reports its own.
- An invalid entry has four parts. The path is the argument or accepted attribute, then any steps into it (a value type's field, a list index); it is empty when the failure concerns the input as a whole. The code is a short stable identifier: the kernel's are a closed list (`required`, `min_length`, `max_length`, `min`, `max`) and a developer-written validation supplies its own. The bound is the declared limit, for kernel codes that have one. The message is optional developer text.
- The kernel stores no English and has no translation machinery. It offers one function that renders a default sentence from a code and its bound.
- Failure detail never contains a value. Text a developer-written function supplies is the developer's responsibility.
- A function step returns `zava.Error!void`, so a foreign error cannot escape one: the compiler refuses it, and the developer maps it to rejected or unavailable.
- A validation function reports any number of entries with `draft.invalid(scope, .email, "disposable_domain")` and returns normally; the kernel stops the action where ADR 0005 says accumulated validation failures stop it. The name is an enum in generated source, so a wrong one is a compiler error on the exact token. A change, an after step or a generic action stops at once with `return scope.reject("insufficient_funds")`, which records the detail and returns `error.Rejected`.
- A value type's validate function has no draft. It returns a code or null, and the kernel supplies the path.
- A constraint broken by a value a change set is an invalid failure like any other, with the path naming the attribute. Those checks run in one pass before the write, so several accumulate.
- The outermost action call clears `scope.failure` on entry, and again when it returns successfully. The slot is set where the failure originates and is meaningful only directly after a call returned a failure error. There is one slot and no stack of failures. The link between the error and the slot is not checked by the compiler; this is the documented cost of the mechanism.
- The function derived for each write action, which runs its validations without executing it, returns `error.Invalid` and fills the same slot.
- A failure is one tagged union over the six kinds, allocated in the scope's allocator (ADR 0008), with a derived debug formatter. Codes are comptime strings; a message formatted at runtime is allocated in the scope's allocator.
- An extension cannot add a failure kind. A data layer maps its native errors to conflict, not found or unavailable, naming identities and relationships from the model.
- An API surface maps kinds to its own protocol. A request it cannot decode is its own failure and never becomes a kernel one, because a caller in Zig cannot produce it: its input is already typed.
- Bulk actions stay addable: a path is a list of steps, so a record index can lead it. Upsert stays addable: a conflict on an identity is what an upsert would resolve rather than report.
