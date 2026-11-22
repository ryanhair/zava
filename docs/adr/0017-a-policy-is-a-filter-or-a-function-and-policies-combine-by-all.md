# A policy is a filter or a function, and policies combine by `all`

A policy is a named rule on some of a resource's actions, and it takes one of two forms. A filter policy is an expression over the record that the data layer evaluates as part of the action's one operation. A function policy is a developer-written function over the context, and optionally one action's input, that the kernel calls before anything else runs. Every policy that covers an action must pass. The only other combinator is a bypass, a function policy that lets the call proceed without consulting the rest. There are no lists of checks inside a policy, no first-decides order and no solver. We chose this because the data layer is the only thing that ever gives an expression a value (ADR 0010), so a rule about a record can only be a filter in the operation, and a rule the kernel must decide itself can only be a function. With both forms fixed in the declaration, the authorization of every action is a build-time fact: a list of functions to call and one filter text per statement.

```zig
pub const policies: []const zava.Policy(@This()) = &.{
    .{ .name = "admin", .on = .all, .bypass = .isAdmin },
    .{ .name = "tenant", .on = .all, .filter = .eq(.tenant_id, .ctx(.tenant_id)), .refuse_as = .not_found },
    .{ .name = "published_or_own", .on = .{ .kinds = &.{.read} }, .filter = .any(&.{
        .eq(.status, .value(.published)),
        .eq(.author_id, .ctx(.{ .actor, .id })),
    }) },
    .{ .name = "signed_in", .on = .{ .kinds = &.{.create} }, .function = .signedIn },
    .{ .name = "author_edits", .on = .{ .actions = &.{ .update, .publish, .destroy } }, .filter = .eq(.author_id, .ctx(.{ .actor, .id })) },
};

pub fn isAdmin(scope: *zava.Scope, context: Context) zava.Error!bool { ... }
```

The spelling is illustrative. Measured on the prototype branch `prototype/policy-typing` (Zig 0.17.1): a misspelled action name, action kind, function name, attribute and relationship in a policy are each a compiler error on the exact token.

## What a policy does on each kind of action

- **Read**: every filter policy is combined by `all` with the action's declared filter and the caller's filter. A record a policy refuses is absent from the result, and a read that returns one record returns null. A filter policy never fails a read.
- **Update and destroy**: the filter policies ride in the operation beside the preconditions (ADR 0016) and read the stored record as it was before the write. A refused record is not written and the call fails as forbidden, or as not found when the policy says `.refuse_as = .not_found`.
- **Create**: the filter policies ride in the create operation and read the record as it will be stored: accepted values, values set by function changes, assignments and generated values. A refused create writes nothing and fails as forbidden.
- **Generic action**: function policies only. There is no record, so a filter policy that covers a generic action is a compile error.
- **Any kind**: a function policy that returns false fails the call as forbidden before any step runs.

## Considered Options

- **Ash's shape**: a policy holds an ordered list of checks where the first to decide wins, every applicable policy must pass, and a check is a module that may be decided strictly, turned into a filter, or run per record at runtime. Rejected because it is what needs a satisfiability solver per call and what makes a denial opaque. A list of first-decides checks is a boolean formula, and the expression language already has `all`, `any` and `not`, so one filter says the same thing in the open.
- **A function policy that reads the record**: rejected. The kernel would have to read every candidate record and filter in the program, which breaks pagination and counts, costs a read on every write, and cannot be lifted to a set.
- **A small evaluator so an expression over the context alone could be decided in the program**: rejected for the third time (ADR 0010, ADR 0016). Without it such an expression on a read could only become a filter that selects nothing, which turns "you may not" into an empty list. So a filter policy that reads nothing from the record is a compile error that says to write a function, the rule ADR 0016 set for preconditions.
- **A bypass that is a filter** (the owner of a record bypasses the other policies): rejected. The authorization of a write would stop being a plain list of named filters, and the data layer could no longer report each refusal the way it reports preconditions. A record-dependent exception is written with `any` inside the policies it applies to.
- **Policies listed in each action's entry**, hoisted into constants where shared, as steps are (ADR 0005): the entry would show everything and no policy would name an action. Rejected because the rule that matters most is the one that must hold on every action, a tenant filter, and listing it per action makes forgetting it once a silent hole. A policy says what it covers, and the full list for an action is printed in its doc comment.
- **A list inside `resource`**: rejected because action names cannot be typed there (ADR 0006): a policy naming an action that was renamed would be reported when the model is lowered, with no location. In a sibling declaration they are compiler errors on the token.
- **An action with no policy is forbidden at runtime** (Ash's default): rejected for a compile error, since the gap is a build-time fact.
- **Not found as the default refusal of an update or destroy**: hides that the record exists. Rejected as the default because the honest answer to a caller who can read a record and may not change it is forbidden, and the kernel cannot know which callers can read it. The policy that must not reveal existence says so.
- **Checking the record after an update as well as before** (Postgres row security's `WITH CHECK`): rejected for now. What an update may set is governed by what the action accepts. It stays addable as a flag on a policy.
- **Field policies** (Ash: hide or forbid single attributes per caller): out of scope. A record would need a "hidden" state per attribute, which is the "not loaded" state ADR 0012 removed, and a response schema would stop being exact. The route in this design is a private attribute and a public expression calculation whose body is a `cond` on the caller.
- **A flag on a call that skips authorization** (Ash's `authorize?: false`): rejected. A trusted caller is a value in the context that a bypass reads, so the exemption is written in the declaration.

## Consequences

- A policy has a name, unique in its resource, what it covers, and exactly one of four bodies: `filter`, `function`, `bypass` (a function) or `open`. It covers every action (`.all`), every action of the listed kinds, or the listed actions.
- Policies are their own declaration beside `resource`, found by the name `policies` (ADR 0001 amended). Its type reads the action names from `resource`, and `resource` reads nothing from it, so there is no dependency loop. Calculation names in a filter are still checked when the model is lowered, and an argument name is checked there against every action the policy covers.
- Once any resource in the domain declares policies, every resource must, and a resource without them is a compile error naming it. A domain in which no resource declares policies has no authorization. This closes the hazard of a declaration found by name: a `policies` declaration that is misspelled or not `pub` would otherwise leave a resource silently open. The kernel also rejects the likely misspellings by name, as it does for `relationships`.
- Every action of a resource must be covered by at least one policy that is not a bypass, else a compile error naming the resource and the action. An action anyone may call is covered by a policy whose body is `open`. A bypass does not count, because an action covered only by a bypass would be open to everyone the bypass refuses. A policy that covers no action is a compile error.
- A function policy is named by declaration name (ADR 0003) and has the signature `fn (*zava.Scope, Context) zava.Error!bool`, or takes a third parameter, the generated input type of the one action it then must cover. The two are told apart by signature, as a calculation's function is (ADR 0010). It never sees a record. It may do I/O through the scope, which is how an external authorization service is asked.
- Order within a call: bypasses in declared order, and the first that returns true ends authorization; then function policies in declared order, and the first that returns false fails the call as forbidden; then the action's steps; then the data layer's operation, which carries the filter policies. A caller refused by a function policy therefore learns nothing about its input. A caller refused by a filter policy may be told its input is invalid first, since constraints and function validations run before the data layer; they concern the input alone.
- When a step makes the kernel read the current record before an update or destroy (ADR 0005), that read carries the filter policies, and a refusal fails there, so no function step sees a record its caller may not write.
- On an update or destroy the data layer reports, in this order of precedence: a missing record, each filter policy that refused, each precondition that failed. The kernel maps a refusal to not found if any refusing policy says `.refuse_as = .not_found`, else to forbidden. Preconditions are reported only for a record the caller may write.
- `refuse_as` has two values, `.forbidden` (the default) and `.not_found`, and has an effect on update and destroy only. A refused create and a function policy always fail as forbidden.
- A comparison with a null operand has no result (ADR 0015), and a policy whose filter has no result refuses. A policy that compares with `.ctx(.{ .actor, .id })` therefore refuses a caller with no actor, with no test for null written.
- The kernel gives the context no meaning here either (ADR 0005). There is no actor, role or permission concept in the kernel; a policy reads whatever fields the developer's context has.
- No action call skips its policies. An action called from a step, a load or a related write receives the same context and its own policies apply; what that means across relationships is decided separately.
- The filter text of every statement stays a build-time constant. An action has two variants, with its filter policies and, for a call a bypass let through, without them.
- The kernel proves nothing about what a filter means: not that it can be satisfied, not that two policies are compatible. What it checks is coverage, form (a filter reads the record; a filter covers no generic action; a function's signature fits what it covers) and names.
- A filter policy is liftable to a set. A function policy does not read a record, so it does not make an action per record. What a refused record means for one record among a set, skip it or fail the set, is decided with bulk actions, as for a failed precondition (ADR 0016).
- Attribute multitenancy, which is reserved, is a filter policy on the tenant attribute covering every action, plus an assignment on every create. Whether an extension can contribute the policy is decided with where authorization lives.
- Forbidden still carries nothing for the caller (ADR 0009). For logs it records the names of the policies that refused, and a not-found failure caused by a policy records them the same way; no API surface shows either.
- The action's doc comment in generated source lists the policies that cover it, in order, with their names and forms.
- A filter policy may cross a relationship with an existence test or a read through a to-one. Whether the destination's policies gate that crossing is decided separately.
- The data layer contract gains three requirements: an update or destroy operation carries named policy filters beside the preconditions and reports each refusal apart from a missing record and from a failed precondition; a create operation carries named filters over the record as it will be stored and writes nothing when one refuses; the read of a current record carries the same filters.
