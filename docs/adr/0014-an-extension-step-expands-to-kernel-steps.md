# An extension step expands to kernel steps

An extension supplies a kind of step as a comptime function from the step's options to kernel steps: built-in steps, related writes, and function steps that name the extension's own declarations. The developer writes the step in an action's step list under the extension's name, and the kernel replaces the entry with its expansion when it lowers the model. The extension states nothing about the step: the attributes it sets, whether it reads the current record and whether it is liftable to a set are derived from the expansion by the rules that already apply to kernel steps (ADR 0005). We chose this because no stated fact can then be wrong, a step has one implementation instead of one per execution mode, and data layers and other extensions only ever meet kernel step kinds.

```zig
.before = &.{
    .{ .state_machine = .{ .transition = .{ .to = .approved } } },
},
```

Here the entry expands to a built-in validation on the current state and a built-in change that sets `state`.

The same mechanism lets an extension add steps to an action that the developer did not list: implicit steps.

## Considered Options

- **An opaque step kind with stated facts** (Ash's shape): a step is a module with a runtime function over the changeset, plus an optional second implementation, `atomic/3`, that returns expressions, and a third for batches. Rejected because the implementations can disagree, the atomic one may decline per call, which makes liftability a runtime fact, and nothing states what the step writes or reads. Stating those facts by hand beside one opaque comptime function fixes the last point only by trusting the extension.
- **Flat step names** (`.{ .transition = ... }`): shorter. Rejected because two extensions, or an extension and a later kernel built-in, can claim one name.
- **A function call that returns the step** (`state_machine.transition(.approved)`): rejected because every resource file would import the extension and the entry would have to be type-erased, which moves its errors from the developer's file into the extension's code.
- **No implicit steps**: an extension supplies only steps the developer lists, and one that needs its step everywhere fails the build where it is missing. This keeps ADR 0005's rule that an action's entry shows its whole pipeline, and it was the first answer. Rejected because what that rule protects is that the pipeline is a build-time fact, which a step added at build time keeps, and because reserved attribute multitenancy needs a step on every create.
- **Extension options inside the action entry** (an `extensions` block per action): gives a misspelled option an exact compiler error. Rejected because what extensions attach to actions is rarely one option per action: an action has no route, one or several, and a policy spans actions. The extension's own options name the action instead.
- **An argument declared by the extension step**, as a related write declares its own: rejected so that an action's input, which is its contract with callers, is wholly visible in its entry.

## Consequences

- The kernel derives the type of a step entry from the registered extensions, as it derives the `extensions` block (ADR 0004): one field per extension, keyed by its name. An extension gives a step type per phase for each resource, so a misspelled extension, step kind, option or attribute, and a step written in a phase it does not belong to, are ordinary compiler errors on the exact token.
- An entry is replaced in place by one or more kernel steps of the phase it was written in. An entry in the after phase may also contribute validations to the before phase, as a related write does (ADR 0013); they run after the developer's before list.
- An expansion yields kernel steps only, never another extension's step.
- An extension step is liftable to a set exactly when it expands to built-in steps only. What an extension can lift is therefore bounded by the catalogue of built-in steps.
- When built-in steps are not enough, the expansion yields a function step naming one of the extension's own declarations. It is called with the resource and the step's normalized options at comptime, then the draft, the scope and the context, and returns `zava.Error!void`. It declares the attributes it sets and whether it reads the current record exactly as a developer's function step does, is per record, and reports failures the same way (ADR 0009).
- A step that needs an argument names one the developer declared in the action. The name is checked when the model is lowered, like other argument names (ADR 0006). An extension step cannot have an argument whose type it derives; that stays a kernel privilege and is reserved for extensions.
- An extension cannot add an attribute: every attribute is a field of the developer's struct (ADR 0001). An extension that needs one requires it and reports its absence from its normalize function.
- An extension may add implicit steps only to actions of a resource that gives the extension options. Giving the options is the visible consent; a resource that gives none gets none.
- Implicit steps have a fixed position: in each phase, an extension's steps go before or after the developer's list, never between its entries, and extensions are ordered as they are registered at the domain root.
- The kernel has no way to switch an implicit step off for one action. An extension that wants one offers its own option.
- Every expanded step keeps its origin in the model: the extension's name and the step kind. The action's doc comment in generated source prints the full pipeline with each step's origin, and a failure records it (ADR 0009).
- Steps declared once for a whole resource stay rejected in the declaration (ADR 0005). A developer who wants them writes a small extension in their own repository, since an extension is only a namespace.
- On a read action an extension may contribute validations on arguments in the before phase and function steps in the after phase, as a developer may. Whether an extension may contribute a filter is decided with authorization.
- There is no kernel mechanism for per-action options. An extension names actions inside its own options, in whatever structure suits it, and a public kernel helper resolves an action name when the model is lowered, reporting a miss with the resource, the extension and the name. The developer's file does not appear in that error, the same weakest error ADR 0004 accepts.
- The extension contract gains three optional parts: a step type per phase for each resource, the function that expands a step, and the function that returns an extension's implicit steps for an action (ADR 0004 amended).
