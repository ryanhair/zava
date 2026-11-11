# Ash anatomy and pain points

Research for issue #2. Researched 2026-11-10 against Ash 3.37.x and current Spark `main`.

**Scope.** How Ash is put together, what it resolves at Elixir compile time versus at runtime, how Spark extensions read and extend the model, and where users and maintainers say it hurts. Each "A build-time-only design would need" note is an observation about what the runtime mechanism does, not a design.

**Confidence markers.** Claims are sourced from Ash/Spark documentation or source unless marked otherwise.

- **[unverified]**: could not be confirmed against a primary source in this pass.
- **[inferred]**: follows from sourced facts but is not stated by a source.
- **[user report]**: a forum post by a user, not a maintainer statement or a measurement I reproduced.

## Summary

1. A resource is a static declaration, which the docs call "really just a configuration file". It has 14 top-level DSL sections, and extensions add more sections to the same module.
2. Spark turns the declaration into a data structure at Elixir compile time, runs transformers, persisters, and verifiers over it, and bakes the result into generated functions on the module. Introspection is a function call that returns constant data.
3. Almost everything that acts on the model does so at runtime by interpreting that data. Changesets, queries, filters parsed from requests, policy solving, calculation placement, and data-layer capability checks all walk the model on each call.
4. The model itself is closed at compile time. What varies at runtime is values (filters, sorts, loads, actor, tenant) and which of several pre-declared strategies applies (data layer versus in-memory, filter versus forbid, atomic versus not).
5. The reported pain clusters in five places: learning curve, compile times driven by compile-time dependencies between modules, errors that lack context, a macro DSL that "doesn't feel like Elixir", and unclear escape hatches.

## 1. What a resource declaration contains

The resource DSL reference lists these top-level sections ([DSL: Ash.Resource](https://ash.hexdocs.pm/dsl-ash-resource.html)):

| Section | Entities or options |
|---|---|
| `attributes` | `attribute`, `create_timestamp`, `update_timestamp`, `integer_primary_key`, `uuid_primary_key`, `uuid_v7_primary_key` |
| `relationships` | `has_one`, `has_many`, `many_to_many`, `belongs_to`, each with an optional nested `filter` |
| `actions` | `create`, `read`, `update`, `destroy`, and generic `action`; nested `argument`, `change`, `validate`, `prepare`, `pipe_through`, `emit`, `metadata`, `pagination`, `filter` |
| `code_interface` | `define`, `define_calculation`, `custom_input` |
| `resource` | options only: `description`, `base_filter`, `default_context`, `short_name` |
| `identities` | `identity` (a uniqueness constraint) |
| `changes`, `preparations`, `validations` | resource-wide `change`, `prepare`, `validate` |
| `pipelines` | `pipeline`: reusable groups of changes, validations, preparations |
| `signals_in` | `from` / `on`: run an action when a signal is emitted |
| `aggregates` | `count`, `exists`, `first`, `sum`, `list`, `max`, `min`, `avg`, `custom`, each with `join_filter` |
| `calculations` | `calculate` with nested `argument` |
| `multitenancy` | options only: `strategy`, `attribute`, `global?` |
| `temporal` | options only: `strategy`, `attribute`, `recorded_at` |

Extensions contribute further sections to the same module. Examples: `policies` and `field_policies` from `Ash.Policy.Authorizer`, `postgres` from AshPostgres, `json_api` from AshJsonApi ([AshJsonApi resource DSL](https://ash-json-api.hexdocs.pm/dsl-ashjsonapi-resource.html)).

Points that matter for a designer:

- **Five action types.** Read, create, update, destroy, and generic. Create and update actions take an `accept` list of attributes plus `argument`s for input that is not stored ([Actions](https://ash.hexdocs.pm/actions.html)).
- **Primary actions.** A primary action is the one Ash uses "in automated situations" such as managing relationships. Asking for a primary action that does not exist is a runtime error ([Actions](https://ash.hexdocs.pm/actions.html)).
- **Behaviour is referenced, not embedded.** Changes, validations, preparations, checks, and calculations are named in the DSL as a module (optionally with options) or as an inline function. The module implements a behaviour and is called at runtime.
- **Declared intent.** The docs state "All behavior is driven by explicit, static declarations" and that a resource does nothing alone and is read by code that acts on it ([Design principles](https://ash.hexdocs.pm/design-principles.html)).

## 2. What Ash derives from it

"Model your domain, derive the rest" is the stated philosophy; the docs name database schemas, API endpoints, authorization rules, state machines, and background jobs as derived ([What is Ash](https://ash.hexdocs.pm/what-is-ash.html)).

| Derived thing | By | When it is produced |
|---|---|---|
| Implicit model parts: `belongs_to` foreign-key attribute, join relationship for `many_to_many`, primary-action flags, default `accept` | Ash core transformers ([`lib/ash/resource/dsl.ex`](https://github.com/ash-project/ash/blob/main/lib/ash/resource/dsl.ex)) | Elixir compile time |
| Lookup caches: primary key, attributes by name, relationships, calculations, unique keys, action inputs | Ash core persisters (same file) | Elixir compile time |
| Model validation (29 verifiers: relationship attributes match, accept lists valid, actions atomic, aggregates supported by the data layer, and more) | Ash core verifiers (same file) | After the module compiles |
| Code interface functions on the domain or resource | `code_interface` / `define` ([Code interfaces](https://ash.hexdocs.pm/code-interfaces.html)) | Elixir compile time (macro-generated functions) |
| Database migrations | AshPostgres `mix ash.codegen`, diffing against stored resource snapshots ([Migrations and tasks](https://ash-postgres.hexdocs.pm/migrations-and-tasks.html)) | Separate dev-time task that writes files |
| JSON:API routes, filter and sort parameters, includes | AshJsonApi; `derive_filter?` and `derive_sort?` default to `true` ([AshJsonApi resource DSL](https://ash-json-api.hexdocs.pm/dsl-ashjsonapi-resource.html)) | Routes at compile time **[inferred]**; request parsing at runtime |
| OpenAPI description | AshJsonApi ([Open API](https://ash-json-api.hexdocs.pm/open-api.html)) | At runtime on each request by default; a mix task can write it to a file instead |
| GraphQL schema, state machines, encryption at rest | AshGraphql, AshStateMachine, AshCloak ([What is Ash](https://ash.hexdocs.pm/what-is-ash.html)) | Not examined in this pass |
| Authorization decisions and read filters | `Ash.Policy.Authorizer` ([Policies](https://ash.hexdocs.pm/policies.html)) | Runtime, per call |
| Module documentation of the DSL configuration | Spark appends an "explain" block to `@moduledoc` ([`lib/spark/dsl.ex`](https://github.com/ash-project/spark/blob/main/lib/spark/dsl.ex)) | Elixir compile time |

The count for Ash core's resource DSL alone is 21 transformers, 10 persisters, and 29 verifiers ([`lib/ash/resource/dsl.ex`](https://github.com/ash-project/ash/blob/main/lib/ash/resource/dsl.ex)).

## 3. How Spark extensions read and extend the model

Spark is the DSL engine under Ash. An extension is a module that supplies data describing a DSL, plus passes over the result.

**What an extension declares** ([Spark.Dsl.Extension](https://spark.hexdocs.pm/Spark.Dsl.Extension.html)):

- `sections`: `Spark.Dsl.Section` structs holding an options schema and `Spark.Dsl.Entity` structs. Each entity names a `target` struct, positional `args`, and a `schema`.
- `transformers`, `persisters`, `verifiers`: the three kinds of pass, described below.
- `dsl_patches`: `Spark.Dsl.Patch.AddEntity` structs that add an entity to another extension's section. A patch is applied only if the target section is patchable or already holds an entity with the same target ([`lib/spark/dsl/extension.ex`](https://github.com/ash-project/spark/blob/main/lib/spark/dsl/extension.ex)).
- `add_extensions` and `module_imports`: exposed as callbacks; their use is not documented on the page. **[unverified]** `add_extensions` pulls in further extensions automatically.

**The three passes.** The documentation is explicit about what each may do:

| Pass | Runs | May modify the model | Notes |
|---|---|---|---|
| Transformer | "during compilation, in dependency order (controlled by `before?/1` and `after?/1`)" | Yes: "Can read and modify any part of the DSL state" | Ordering is declared pairwise between transformer modules ([Spark.Dsl.Transformer](https://spark.hexdocs.pm/Spark.Dsl.Transformer.html)) |
| Persister | "during compilation, always after all transformers" | By convention only through `persist/3` | Caches computed values under a key |
| Verifier | "after the module is compiled" | No: "Read-only" | "Do not create compile-time dependencies between modules", so it may inspect other resources ([Spark.Dsl.Verifier](https://spark.hexdocs.pm/Spark.Dsl.Verifier.html)) |

Transformers can add, replace, and remove entities, set options, and persist values (`add_entity`, `replace_entity`, `remove_entity`, `set_option`, `persist`). They also have `eval/3`, which injects code into the module and which the docs say to use "extremely sparingly" ([Spark.Dsl.Transformer](https://spark.hexdocs.pm/Spark.Dsl.Transformer.html)).

**How the model is built and stored** ([`lib/spark/dsl.ex`](https://github.com/ash-project/spark/blob/main/lib/spark/dsl.ex), [`lib/spark/dsl/extension.ex`](https://github.com/ash-project/spark/blob/main/lib/spark/dsl/extension.ex)):

1. `use Spark.Dsl.Extension` generates a macro per section and per entity, plus a module per entity that builds the target struct.
2. While the resource module body is expanding, those macros accumulate section config in the compiler process dictionary under `{module, :spark, section_path}`.
3. A `@before_compile` hook collects that state, runs transformers then persisters, and stores the result in `@spark_dsl_config`.
4. The module gets generated accessors: `spark_dsl_config/0`, `entities/1`, `fetch_opt/2`, `persisted/2`, and per-path variants. These return literal data compiled into the module.
5. An `@after_verify` hook runs the verifiers and raises `Spark.Error.DslError` on failure.

**How the model is read.** `Spark.Dsl.Extension.get_entities/2`, `get_opt/5`, and `get_persisted/3` accept either the DSL state map (inside a pass) or the module (anywhere else). For a module they call the generated accessor, falling back to the process dictionary and then the module attribute when the module is still compiling ([`lib/spark/dsl/extension.ex`](https://github.com/ash-project/spark/blob/main/lib/spark/dsl/extension.ex)). `Ash.Resource.Info` is a thin layer over this: `attributes/1`, `actions/1`, `relationship/2`, `primary_key/1`, and so on, most of which accept either form ([Ash.Resource.Info](https://ash.hexdocs.pm/Ash.Resource.Info.html)).

Two details worth knowing:

- **Accessors were a performance fix.** Spark originally read options by walking a nested map. It now generates a function clause per section path and option, because "the current naive implementations were taking quite a bit of time during the execution of Ash actions" (Zach Daniel, [Elixir Forum](https://elixirforum.com/t/recent-spark-performance-improvements-should-have-significant-positive-effects-on-ash-application-performance/59076)). Introspection is cheap but it is still on the runtime hot path.
- **One option path reads application config.** `get_opt` with `configurable?: true` consults `Application.fetch_env/2` at call time, so some model options can be overridden by runtime configuration ([`lib/spark/dsl/extension.ex`](https://github.com/ash-project/spark/blob/main/lib/spark/dsl/extension.ex)).

**Source annotations.** Sections and options carry annotations (`get_section_anno/2`, `get_opt_anno/3`) so that passes can point errors at the declaring source location ([Spark.Dsl.Transformer](https://spark.hexdocs.pm/Spark.Dsl.Transformer.html)).

## 4. Compile time versus runtime

### Resolved at Elixir compile time

- The full model: every section, entity, and option, after transformers have filled in implicit parts.
- Persisted lookup caches.
- Verifier checks on the model, including cross-resource checks.
- Code interface functions.
- Expression syntax: `expr(...)` is a macro, so an expression written in the DSL is parsed into a data structure at compile time. Its references are left as templates (`^actor(:id)`, `^arg(:name)`, `^context(:key)`) and filled in per call ([Expressions](https://ash.hexdocs.pm/expressions.html)).
- A policy-expression cache: the policy extension has a `CachePolicyExpressions` persister and field-policy transformers ([`lib/ash/policy/authorizer/authorizer.ex`](https://github.com/ash-project/ash/blob/main/lib/ash/policy/authorizer/authorizer.ex)). **[unverified]** exactly what it precomputes.

### Runtime-dynamic mechanisms

Each entry gives what happens at runtime, then what a build-time-only design would have to put in its place.

**4.1 Changesets.** An `Ash.Changeset` is a runtime struct holding `resource`, `action`, `params`, `attributes`, `arguments`, `atomics`, `errors`, and six hook lists ([Ash.Changeset](https://ash.hexdocs.pm/Ash.Changeset.html)). Building one looks up the action by name, casts each input by the attribute's type, and runs the action's changes and validations in definition order. Changes add hooks to the struct as closures, so the hook pipeline for one call is not known until the changes have run. The lifecycle is fixed: `around_transaction`, `before_transaction`, `around_action`, `before_action`, data layer, `after_action`, `after_transaction` ([Actions](https://ash.hexdocs.pm/actions.html)).

- *A build-time-only design would need:* a per-action input type and a statically known pipeline of steps for each action, in place of name lookup, per-field dynamic casting, and hook lists assembled during the call. Hooks registered conditionally at runtime have no direct static counterpart.

**4.2 Dispatch to behaviour modules.** Changes, validations, preparations, checks, calculations, and data layers are stored in the model as module references and called through behaviours at runtime. This is also the root of Ash's compile-dependency problem (section 5.2).

- *A build-time-only design would need:* the implementing function to be resolved when the model is built, so the call is direct.

**4.3 Filters and queries built from requests.** `Ash.Filter.parse_input/2` accepts keyword lists, maps, and "maps with string keys" at runtime. It resolves each key against the resource through `Ash.Resource.Info.public_attribute/2` and its relationship, calculation, and aggregate equivalents, walks relationship paths to the related resource, and returns a `NoSuchField` error for unknown names ([Ash.Filter](https://ash.hexdocs.pm/Ash.Filter.html), [`lib/ash/filter/filter.ex`](https://github.com/ash-project/ash/blob/main/lib/ash/filter/filter.ex)). `parse_input` restricts to public fields and honours field policies; the docs warn "Do not pass user input directly to `Ash.Query.filter/2`, it will not be sanitised". **[unverified]** how values are type-cast in this path; that part of the source was not read.

- *A build-time-only design would need:* a generated per-resource parser or lookup table from field name to a typed field descriptor, with the set of filterable fields, operators per type, and reachable relationship paths fixed at build time. The filter tree itself stays a runtime value. Relationship traversal makes the reachable set recursive, so depth has to be bounded or handled by per-resource parsers that call each other.

**4.4 Expression placement.** Expressions "are already executable in Elixir or in the data layer", and Ash decides per use. The documented example: a `full_name` calculation runs as SQL when loaded in a query, and in Elixir when loaded later with `reuse_values?: true` ([Expressions](https://ash.hexdocs.pm/expressions.html), [Calculations](https://ash.hexdocs.pm/calculations.html)). Expressions follow SQL `NULL` semantics in both places.

- *A build-time-only design would need:* either two generated evaluators per expression (a data-layer translation and an in-memory function) with identical semantics, or a decision to support only one placement. The choice between them can be a runtime branch over two fixed code paths.

**4.5 Calculations.** Expression calculations can be filtered and sorted on. Module calculations implement `load/3` and `calculate/3`, run in Elixir over a list of records, and reach the data layer only if they also implement the optional `expression/2` callback ([Calculations](https://ash.hexdocs.pm/calculations.html)). **[inferred]** a module calculation without `expression/2` cannot be used in a filter or sort; the guide implies this but does not state it.

- *A build-time-only design would need:* whether a calculation is pushable to be a build-time property of its declaration, so that filtering on a non-pushable one is a build error and not a runtime one.

**4.6 Data-layer capabilities.** `Ash.DataLayer.can?/2` answers feature queries at runtime, such as `:transact`, `{:atomic, :update}`, `{:join, resource}`, `{:aggregate, kind}`, `{:filter_expr, struct}`, `:expression_calculation`, and `{:lock, type}` ([Ash.DataLayer](https://ash.hexdocs.pm/Ash.DataLayer.html)). Some of this is already checked by verifiers (`ValidateAggregatesSupported`, `ValidateActionTypesSupported`). **[unverified]** how much of the remaining selection logic runs per call; the docs do not describe it.

- *A build-time-only design would need:* capabilities as build-time constants of the data layer, so an unsupported combination fails the build.

**4.7 Policy evaluation.** Entirely per call ([Policies](https://ash.hexdocs.pm/policies.html), [`lib/ash/policy/authorizer/authorizer.ex`](https://github.com/ash-project/ash/blob/main/lib/ash/policy/authorizer/authorizer.ex)):

1. Policies whose condition matches the request are selected. All applicable policies must pass; a `bypass` that passes short-circuits the rest.
2. Each check is a fact keyed by `{check_module, opts}` with value true, false, or unknown. Simple checks answer from the actor and request. Filter checks return an expression.
3. A boolean satisfiability solver finds the scenarios (assignments of facts) under which the request is authorized. "The SAT solver only computes facts it needs to decide the request", so checks must be side-effect free.
4. For reads, the remaining scenarios become a filter: checks within a scenario are joined with `and`, scenarios with `or`. The default `access_type` is `:filter`, so unauthorized rows are silently excluded and the caller sees fewer results or `NotFound`, not `Forbidden`.
5. For creates, a filter check is verified after the insert, inside the transaction, with rollback if no row matches.
6. Field policies rewrite the query: a forbidden field in a filter or sort becomes a conditional that yields `nil`, and forbidden values in results become `%Ash.ForbiddenField{}`.

- *A build-time-only design would need:* the policy set per action is closed, so the boolean structure can be solved or simplified at build time into a fixed decision procedure per action, parameterised by the simple-check results that depend on the actor. The actor-dependent facts and the resulting filter value remain runtime. Whether a general solver is needed at all, or only at build time, is the open question this raises.

**4.8 Atomic updates.** Whether an update can run as one data-layer statement depends on every change and validation implementing an `atomic/3` callback and every type supporting atomic casting. If not, "you will get an error unless you have set `require_atomic? false`" ([Update actions](https://ash.hexdocs.pm/update-actions.html)). A `VerifyActionsAtomic` verifier exists, and `Ash.Changeset.fully_atomic_changeset/4` can still return `{:not_atomic, reason}` at runtime ([Ash.Changeset](https://ash.hexdocs.pm/Ash.Changeset.html)), so the property is checked partly at compile time and partly per call.

- *A build-time-only design would need:* atomicity to be a property decided once per action from its declared changes.

**4.9 OpenAPI generation.** By default AshJsonApi regenerates the description on each request to the endpoint; the `open_api_file` option serves a pre-generated file ([Open API](https://ash-json-api.hexdocs.pm/open-api.html)).

- *A build-time-only design would need:* the description emitted as a build artifact or embedded constant.

**4.10 Errors.** Errors are runtime exception structs built on the Splode library, grouped into four classes in priority order: Forbidden, Invalid, Framework, Unknown. Multiple errors are combined under the highest class present, with the individual errors in an `errors` list. API extensions use a protocol to decide how each error is rendered ([Error handling](https://ash.hexdocs.pm/error-handling.html)).

- *A build-time-only design would need:* a closed set of error shapes per action known at build time, since protocol dispatch on arbitrary exception structs is not available.

**4.11 Migrations.** Not runtime, but not compile time either: a dev-time task compares the current model with stored snapshots, writes migration files, and asks the developer interactively whether a changed table name is a rename ([Migrations and tasks](https://ash-postgres.hexdocs.pm/migrations-and-tasks.html)).

- *A build-time-only design would need:* the same shape, a build step that reads the model and a stored prior state. Renames cannot be inferred from the model alone.

## 5. Pain points

### 5.1 Learning curve

The most consistently reported problem, and conceded by the team.

- "The learning curve is definitely the biggest one, IMO. It's a lot better than it was" (sevenseacat, Ash core team, [Elixir Forum](https://elixirforum.com/t/my-thoughts-on-ash/69829)).
- "The Ash learning curve doesn't seem worth it at this point" for small projects (mike1o1, **[user report]**, same thread). The same user says the book and generators later made it click.
- "unlike Ecto, Ash is not a library; Ash is your application" (caslu, **[user report]**, same thread): the framework cannot be adopted partially or removed later.
- Documentation "often feel[s] auto-generated, with crucial details added as an afterthought" (egeersoz, **[user report]**, [Elixir Forum](https://forum.elixirforum.com/t/my-thoughts-on-ash/69829/18)).

### 5.2 Compile times

The cause is structural, not incidental. A resource names its change, validation, and check modules in the DSL. In Elixir that reference creates a dependency from the resource to the module, and because resources are introspected at compile time, dependencies become transitive.

- Zach Daniel raised this with the Elixir core team in 2022: `change HashPassword` creates a compile-time dependency on a module needed only at runtime. His workaround of disabling the lexical tracker during alias expansion forced users to mark aliases `warn: false`. José Valim's position was that a module called at runtime must keep its runtime dependency ([elixir-lang-core](https://groups.google.com/g/elixir-lang-core/c/eOqotA8OyKE/m/X1YRJs9NAgAJ)).
- This is why Spark splits verifiers from transformers: verifiers run after compilation precisely so that looking at another resource does "not create compile-time dependencies" ([Spark.Dsl.Verifier](https://spark.hexdocs.pm/Spark.Dsl.Verifier.html)).
- Inline functions in resources are the common trigger. One project's incremental compiles went from 2 to 3 seconds to 8 to 10 seconds; the fix was moving inline action hooks into their own modules (joangavelan, **[user report]**, [Elixir Forum](https://elixirforum.com/t/reducing-incremental-compilation-times-in-phoenix-ash-project/72113)). Zach Daniel's first recommendation for slow resources is to "remove as many anonymous functions from your resources" as possible ([Elixir Forum](https://elixirforum.com/t/strategies-to-make-resources-compile-faster/72265)).
- Macro-generated code is the other cost. One resource compiled in about 11.3 s with `code_interface` and 2.3 s without; a domain went from 285 ms to 6.4 s (sezaru, **[user report]**, [Elixir Forum](https://elixirforum.com/t/using-code-interface-makes-resource-slow-to-compile/73196)). Zach Daniel then reported "pretty significant improvements in `main`", and users in the thread reported drops from about 32 s to 9 s and from 18 s to 6 s.
- Some resources "take more than 30 seconds" to compile (sezaru, **[user report]**, [Elixir Forum](https://elixirforum.com/t/strategies-to-make-resources-compile-faster/72265)). No root cause was confirmed in that thread.
- A Spark change to how DSL data is stored cut one 80-resource application's full compile from about 1m26s to 41s (frankdugan3, **[user report]**, [Elixir Forum](https://elixirforum.com/t/recent-spark-performance-improvements-should-have-significant-positive-effects-on-ash-application-performance/59076)).

Observation for the Zig design: the Elixir problem is recompilation cascades between separately compiled modules. Zig compiles a program as a whole, so the analogous risk is different in kind: total comptime evaluation cost and how much is redone on each change. This research does not establish what that cost is.

### 5.3 Error messages and debugging

- Hidden limits surface late: "until you attempt something ordinary and run into cryptic errors" (egeersoz, **[user report]**, [Elixir Forum](https://forum.elixirforum.com/t/my-thoughts-on-ash/69829/18)).
- A declarative configuration gives little to reason about locally: "There is often no reasoning about config files"; understanding one can mean reading the program that consumes it (skybrian, **[user report]**, [Hacker News](https://news.ycombinator.com/item?id=37797659)). The same commenter suggested a `make -n` style "show what you would do" facility. Zach Daniel's reply cited "as sane config as possible" and functional hooks.
- Policy failures are opaque by default. Detailed breakdowns must be requested or enabled with `show_policy_breakdowns?`, which "should only ever be used in development mode". Because the solver computes only the facts it needs, a breakdown can show checks as unknown, and "the first denying policy in source order is usually the responsible one" ([Policies](https://ash.hexdocs.pm/policies.html)).
- The default `:filter` access type turns an authorization failure into missing rows, which reads as a data bug and not a permission problem ([Policies](https://ash.hexdocs.pm/policies.html)). **[inferred]** as a debugging hazard; the docs describe the behaviour without calling it one.
- Some model errors appear only at runtime: a missing primary action, a non-atomic update ([Actions](https://ash.hexdocs.pm/actions.html), [Update actions](https://ash.hexdocs.pm/update-actions.html)).
- **[unverified]** A search summary attributed to a maintainer the statement that errors lack "important context that would make debugging much easier"; I could not locate the original post.

### 5.4 The macro DSL

- "doesn't really feel like writing Elixir at all"; Ash "feels more like its own language" (egeersoz, **[user report]**, [Elixir Forum](https://forum.elixirforum.com/t/my-thoughts-on-ash/69829/18)).
- "things just got too magical", drawing a comparison with Devise (caslu, **[user report]**, [Elixir Forum](https://elixirforum.com/t/my-thoughts-on-ash/69829)).
- Testing feels beside the point when most of a resource is declaration: "coverage is a useless metric to define code safety/quality with Ash" (caslu, **[user report]**, same thread).
- **[unverified]** Editor and language-server support for the DSL is a known difficulty; I found no primary source in this pass.

### 5.5 Escape hatches

Ash's stated position is "multi-tiered configurability and escape hatches all the way down" ([What is Ash](https://ash.hexdocs.pm/what-is-ash.html)). Zach Daniel lists the layers as functional hooks, manual actions that take over the data-layer call, and generic actions, and adds that Ash "is just an Elixir library", so plain Elixir is always available ([Hacker News](https://news.ycombinator.com/item?id=37797659)).

The complaint is about discoverability, not existence: it is "unclear when and how you're supposed to deviate from 'the Ash way,' which isn't well documented" (egeersoz, **[user report]**, [Elixir Forum](https://forum.elixirforum.com/t/my-thoughts-on-ash/69829/18)).

Using a hatch has a cost that the docs do state. A function-based change makes an update non-atomic; a module calculation without an expression stays out of the data layer ([Update actions](https://ash.hexdocs.pm/update-actions.html), [Calculations](https://ash.hexdocs.pm/calculations.html)). Each drop to imperative code removes that piece from what can be derived.

## 6. Observations for the design

These restate findings; they are not decisions.

1. **Ash already has a closed-world model at compile time.** What it lacks is compile-time *use* of that model: nearly every consumer interprets it per call. The Zig bet is about moving the consumers, not the model.
2. **The three-pass split is load-bearing.** Transformers mutate, persisters cache, verifiers check across resources. The split exists partly to work around Elixir's dependency tracking. Whether an ordered mutation phase is needed at all, given that pairwise `before?`/`after?` ordering is the fragile part, is worth deciding explicitly.
3. **Extensions add both vocabulary and passes.** A Spark extension contributes new sections to the declaration surface, can patch entities into another extension's sections, and can rewrite the model. Reading the model is the easy part.
4. **The runtime-varying parts are values over a fixed model.** Filters, sorts, loads, actor, tenant, and pagination vary; fields, operators, relationships, and policies do not. This matches the closed-world note in the map.
5. **Policies are the hardest mechanism to move.** They combine a solver, lazily computed facts, filter generation, and post-hoc checks inside transactions.
6. **Each escape hatch has a derivation cost.** Ash surfaces that cost mostly at runtime (the atomic error). A build-time design can surface it when the model is built.
7. **Errors need source locations.** Spark carries annotations for exactly this reason, and users still describe the errors as cryptic.

## Not covered

- AshGraphql, AshPhoenix, AshAuthentication, AshStateMachine, and AshOban internals.
- The body of the policy `Checker` module and the SAT solver integration.
- Bulk actions, notifiers, `manage_relationship`, and multitenancy mechanics.
- The Ash Discord, which is where most support happens and is not publicly indexable.
- Any measurement of my own; all timings are user reports.
