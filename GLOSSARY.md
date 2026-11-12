# Zava

A Zig framework for data-backed backend services, built on Ash's principles: the domain is declared as data, actions are the only way in, and everything else is derived at build time.

## Language

### Declaring

**Domain**:
The complete, closed set of resources in a build. There is exactly one, and it is the root every derivation starts from. Unlike an Ash domain, it is not a grouping of some of an application's resources.
_Avoid_: Application, registry, context, API

**Resource**:
A struct type together with its `resource` declaration; the declared kind of thing the application acts on. A resource need not be persisted.
_Avoid_: Entity, model, schema

**Record**:
One value of a resource's struct.
_Avoid_: Row, instance, entity

**Declaration**:
What the developer writes to describe a resource.
_Avoid_: DSL, schema, definition

**Model**:
The normalized build-time data lowered from all declarations; the only thing derivations and extensions read.
_Avoid_: Schema, metadata, domain model

**Attribute**:
A named, typed, stored value of a record. Every field of a resource's struct is an attribute, and nothing else lives in the struct. An attribute is private unless declared public, and may be declared sensitive.
_Avoid_: Field, column, property

**Public**:
Said of an attribute or calculation that an API surface may expose. Neither is public unless declared so.
_Avoid_: Visible, exposed

**Sensitive**:
Said of an attribute, calculation or value type whose values are kept out of logs and failure detail.
_Avoid_: Secret, private, redacted

**Built-in type**:
A type supplied by the kernel for a kind of value that Zig has no type of its own for, such as a UUID or an instant. The list is closed.
_Avoid_: Primitive, scalar, leaf

**Value type**:
A developer-declared type that gives values a domain meaning, such as an email address or a money amount, and carries its own constraints.
_Avoid_: Semantic type, custom type, newtype, wrapper

**Constraint**:
A declared bound on the values a value type or an attribute may hold.
_Avoid_: Rule, restriction, limit

**Calculation**:
A named, typed value computed for a record rather than stored, either by an expression or by a developer-written function. It is computed only when asked for, and its name is unique among the resource's attributes, calculations and relationships.
_Avoid_: Computed field, virtual attribute, derived attribute

**Expression**:
A typed computation over one record, written as data: it may read the record's attributes and calculations, the arguments of the action it belongs to, literal values, and records reached through a relationship.
_Avoid_: Query, condition, predicate, formula

**Filter**:
An expression with a boolean result, used to select records.
_Avoid_: Where clause, condition, criteria

**Relationship**:
A named connection from one resource to another, of one of four kinds: belongs-to, has-one, has-many, or many-to-many. A many-to-many relationship always names a join resource.
_Avoid_: Association, reference, link

**Source**:
The resource that declares a relationship.
_Avoid_: Parent, owner

**Destination**:
The resource a relationship points to.
_Avoid_: Target, child

**Join resource**:
The resource whose records pair source records with destination records in a many-to-many relationship.
_Avoid_: Through table, join table, link table

**Primary key**:
The attributes that identify a record. Every resource has exactly one.
_Avoid_: Key, id

**Identity**:
A named set of attributes, other than the primary key, whose values are unique across the records of a resource.
_Avoid_: Unique constraint, unique index, key

### Acting

**Action**:
A named, declared operation on a resource, of one of five kinds: create, read, update, destroy, or generic. Actions are the only way to read or write records.
_Avoid_: Operation, endpoint, method, command

**Generic action**:
An action that is not a create, read, update or destroy. Never called a bare "action".
_Avoid_: Custom action

**Input**:
The whole value passed to an action, made of accepted attributes and arguments.
_Avoid_: Params, payload, body

**Accepted attribute**:
An attribute of the resource that an action allows its input to set.

**Argument**:
A named, typed part of an action's input that is not an attribute of the resource.
_Avoid_: Parameter, option

**Query**:
What a caller supplies to shape one call of a read action: a filter, a sort and a request for a page.
_Avoid_: Options, params

**Sort**:
An ordered list of terms that decides the order of the records a read action returns. Each term names an attribute or a calculation and a direction.
_Avoid_: Order, ordering, order by

**Page**:
A bounded run of records from a read action, together with what is needed to ask for the adjoining run. A page is asked for in one of two ways: keyset, from a cursor, or offset, from a count of records to skip.
_Avoid_: Window, batch, chunk

**Cursor**:
An opaque value that marks a position in a sorted read.
_Avoid_: Keyset, token, bookmark

**Context**:
The developer-written value passed with every action call and readable wherever the action runs. There is one context type per domain.
_Avoid_: Actor, session, scope

**Scope**:
The kernel-defined value passed with every action call beside the context. It supplies the memory and I/O the call works with and carries the open transaction from an action to the actions its steps call.
_Avoid_: Session, unit of work, environment, context

**Step**:
One declared unit of an action's execution, either a validation or a change.
_Avoid_: Hook, callback, middleware

**Validation**:
A step that inspects and may fail, and never mutates.
_Avoid_: Check, guard

**Change**:
A step that mutates the draft.
_Avoid_: Mutation, transform

**Phase**:
Where in an action's execution a step runs: before, after, or after commit.
_Avoid_: Stage, hook point

**Draft**:
The per-call value an action's steps work on: the input and the attribute values to be written.
_Avoid_: Changeset

**Failure**:
The outcome of an action call that did not complete, made of a failure kind and its detail.
_Avoid_: Error, exception, fault

**Failure kind**:
One of the six reasons an action call can fail: invalid, forbidden, not found, conflict, rejected, or unavailable. The list is closed.
_Avoid_: Error type, error class, error code

### Deriving

**Kernel**:
The part of the framework that everything else builds on: the model, actions, and the extension mechanism.
_Avoid_: Core

**Derivation**:
Anything produced from the model at build time, such as SQL, request handlers, or an OpenAPI description.
_Avoid_: Generator, codegen, code generation

**Generated source**:
Zig source written by the kernel at build time and compiled into the program; it holds the types and signatures a developer writes code against, other than records.
_Avoid_: Generated code, output, facade

**Extension**:
A unit outside the kernel that adds declaration options and derivations.
_Avoid_: Plugin, adapter, module

**Description**:
Data by which an extension states a type or function a developer will write code against, for the kernel to write into generated source.
_Avoid_: Template, stub, spec

**Command**:
A named piece of an extension that the build runs on request, with the model as data, to write files that nothing compiles.
_Avoid_: Task, script, generator, build-run code

**Data layer**:
An extension that persists and retrieves records.
_Avoid_: Backend, store, repository

**API surface**:
An extension that exposes actions to callers outside the program.
_Avoid_: Interface, transport, frontend

**Binding**:
The part of an extension that connects it to one third-party library.
_Avoid_: Adapter, driver, wrapper, integration
