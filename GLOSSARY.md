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
A named, typed, stored value of a record. Every field of a resource's struct is an attribute, and nothing else lives in the struct.
_Avoid_: Field, column, property

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
