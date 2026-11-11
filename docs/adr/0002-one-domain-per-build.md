# One domain per build

A build has exactly one domain: the complete, closed set of its resources, and the root every derivation starts from. Ash allows many domains per application, each grouping some of its resources; we deliberately do not follow it. Relationships cross any grouping freely, and migrations, the OpenAPI description and whole-model validation all need every resource, so a root naming the whole set is required either way. Making that root the domain gives one concept where Ash's shape would need two, and states the closed world in one place.

## Considered Options

- **Many domains, as Ash, plus a root that lists them**: keeps Ash's meaning of the word and allows settings shared by a group of resources. Rejected because the jobs an Ash domain does mostly do not transfer: the code interface it hosts is dropped (calling an action is an ordinary Zig call), Zig namespaces and files already group resources, and no decision made so far needs per-group settings. A grouping concept can be added later without breaking anything; removing one after extensions depend on it cannot.
- **One root under another name (for example "application")**, leaving "domain" free for an Ash-style group: rejected because nothing yet calls for the group, and "the domain is declared as data" already names the root.

## Consequences

- "Domain" means something different here than in Ash: the whole closed set, not a bounded-context group. Readers arriving from Ash need to be told.
- There are no per-group settings. A shared setting applies to the whole build or to one resource.
- A build cannot be divided by domain into several API surfaces or several data stores. If authorization, multitenancy or a second surface later needs a group of resources, that group is a new concept with its own name.
- Grouping resources for readability is done with ordinary Zig namespaces and files and has no meaning to the framework.
