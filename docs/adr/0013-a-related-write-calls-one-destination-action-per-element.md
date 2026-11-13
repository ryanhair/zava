# A related write calls one destination action per element; there is no sync

An action writes records across a relationship with a related write: a built-in step that names one relationship, one action of its destination and one argument, and calls that action once for each element of the argument, inside the caller's transaction. An update that adds, edits and removes comments declares three related writes and three arguments, and the caller says which records to create, which to update and which to destroy. This replaces Ash's `manage_relationship`, where one argument holds the desired list and the framework reads the stored records and works out the operations. We chose it because the operations of every call are then a build-time fact (ADR 0005), no read of the stored records is needed, and a partial list can never destroy data.

```zig
.after = &.{
    .{ .write_related = .{ .relationship = .comments, .action = .create, .argument = .add_comments } },
    .{ .write_related = .{ .relationship = .comments, .action = .remove, .argument = .remove_comments } },
},
```

## Considered Options

- **Sync** (Ash's `direct_control`): one argument is the whole desired list; the kernel reads the stored records, creates the missing, updates the matching and destroys the rest. Rejected because every update pays for a read of the current records, through a read action and under a policy that would have to be chosen; the mix of operations is only known per call; and a caller that sends a partial list, or cannot tell an omitted list from an empty one, silently destroys data. Not designed, and reserved: it must stay addable as a further step kind over the same destination actions without changing the related write.
- **No built-in, only a function step that calls the destination's actions**: already possible, and it stays the escape for everything below. Rejected as the only route because the argument's type, its place in the request and its OpenAPI schema would each be written by hand, and the nested input could not be checked before the first write.
- **Belongs-to through the same step**: the destination would have to be written before the source and its key set on the source, which is a change in the before phase and a different mechanism. Rejected: the action accepts the foreign-key attribute, and creating the destination inline is a function step. Reserved on the same terms as sync.
- **Many-to-many through the same step**: what is written is a join record. Rejected in favour of declaring a has-many relationship to the join resource and writing that, the route ADR 0012 already gives for loading join records. Relating is the join resource's create and unrelating is its destroy.
- **One argument per relationship holding a list per operation**: rejected because one step, one action and one argument is the smaller primitive, and the developer names each argument.

## Consequences

- A related write accepts a has-one or a has-many relationship. Any other kind is a compile error.
- It may sit only in the after phase of a create or an update, as an ordinary entry in the list, and runs in written order among the other after steps. It is not allowed on a destroy: what happens to the records related to a destroyed record is a referential rule for the data layer and migrations.
- The named action is a create, update or destroy of the destination. Source and destination must use the same data layer, so a related write is always atomic; across data layers the route is a function step, where the developer owns the gap.
- The step declares its argument; nothing is added to the action's argument list. The name shares the namespace of the action's input, so a clash with an accepted attribute or another argument is a compile error. The argument is always optional, and omitted and empty both mean no calls.
- The element type is generated source (ADR 0003), named after the source action and the argument. For a create it is the destination action's input without the foreign-key attributes. For an update it is the destination's primary key plus that input without the foreign-key attributes. For a destroy it is the primary key plus the action's arguments. For a has-many the argument is a slice of elements; for a has-one it is one optional element.
- The step fills the foreign key from the stored source record. A destination create must accept the foreign-key attributes, else a compile error. A destination update may accept them, but a related write never exposes them, so a record cannot be moved to another source this way.
- An update or a destroy reaches only records related to the source. The kernel adds equality on the foreign key to the match of the destination's operation beside the primary key, so it stays one statement with no prior read, and a record related to another source fails as not found. This is internal to the kernel: for a developer, update and destroy still take a primary key (ADR 0005 amended).
- A second has-one record is not checked by the step. It is a conflict raised by the data layer.
- In the before phase of the source action the kernel runs, over every element, the function ADR 0005 derives for the destination action: its input constraints and the validations that need no current record. The entries accumulate with the source's own validation failures, and nothing is written if there are any (ADR 0005 amended). A failure that only arises while the destination action executes stops at that element and rolls back the whole call.
- A failure keeps the destination action as its origin. The path of an invalid entry, and of a not-found failure, is prefixed with the argument name and the element's index, as in `add_comments[2].body`, so it is a path into the caller's input (ADR 0009 amended).
- The destination action runs whole, with the same context and scope: its own steps, including its own related writes, so element types nest. A cycle through actions is a compile error. Its after-commit steps run after the outermost commit.
- The destination action's result and loads are discarded. To return the written records the source action declares a load (ADR 0012), which is read after the after phase.
- Elements are processed in order, one call each. The model records a related write as per record, and as liftable to a set exactly when its destination action is, so bulk actions can later take the whole slice in one operation without a change to the declaration.
- Over HTTP the argument is a member of the request body under its name: an array of objects, or one object for a has-one, each encoded as the surface encodes that destination action's input, without the foreign key and with the primary key for an update or destroy. The OpenAPI schema is derived from the same generated type. The destination action need not be exposed as an operation: naming it in the step is the consent, as with loads.
- The destination action's policy is expected to apply to every call a related write makes; that is decided with authorization.
- Whether a related write takes a condition is decided with the catalogue of built-in steps.
