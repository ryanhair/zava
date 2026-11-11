# Zig prior art: data access, HTTP, and frameworks

Research for issue #4. Snapshot date: **2026-11-10**. Zig stable is 0.17.1 (released 2026-11-02; 0.17.0 on 2026-10-01; master is 0.18.0-dev) per <https://ziglang.org/download/index.json>.

## How to read this

- Maintenance facts (last push, stars, open issues, `minimum_zig_version`) were read from the GitHub API and each repository's `build.zig.zon` / README on the snapshot date.
- Technique descriptions were read from the source at each repository's default-branch HEAD on the snapshot date.
- **Nothing was compiled.** No Zig toolchain was available in the research environment, so "targets 0.17" always means *the project declares it* (README, `minimum_zig_version`, or CI), not that a build was observed. Treat every 0.17 compatibility statement as **declared, not locally verified**.
- Performance numbers are each project's own claims and are **unverified**.
- Star counts are a weak proxy for adoption; no download or production-usage data exists for any of these.

## Summary

1. **Postgres**: `karlseguin/pg.zig` is the only native driver that is both maintained and widely depended on. Every other Postgres-speaking Zig project found either wraps it, forks it, or is dormant. There is no maintained libpq *binding*; only a build-system port of the C library.
2. **HTTP**: three live options with different I/O models: `karlseguin/http.zig` (own epoll/kqueue loop plus thread pool, most adopted, no TLS), `lalinsky/dusty` (written against `std.Io`, llhttp parser, TLS, young), and `std.http.Server` (in the standard library, a per-connection protocol state machine with no router, pool, or limits). `zigzap/zap` is archived. `tardy-org/zzz` is self-described alpha on its own runtime.
3. **Zig 0.16 moved I/O behind an interface (`std.Io`)** and the ecosystem is mid-migration. The I/O model of a wrapped library is now the main compatibility axis: pg.zig's TLS path (OpenSSL) fails under non-blocking `std.Io` backends, and http.zig accepts an `io` but still runs its own event loop and thread pool.
4. **Frameworks**: Jetzig/JetQuery (the best-known Zig "Rails") declare Zig 0.15 and have not reached 0.16 or 0.17. Tokamak tracks 0.17.1 and derives OpenAPI from handler signatures. Two very young projects (`nilo`, `zchema`) do "types are the contract" derivation on 0.17 and are the closest prior art to this effort's central bet.
5. **Comptime techniques** fall into four families: handler-signature reflection, type-state query builders that render SQL at comptime, `@typeInfo`-driven row/JSON mapping, and build-step code generation. Each has a documented failure mode, listed in the last section.

## Zig 0.16 / 0.17 context that shapes everything below

- **I/O as an interface.** Zig 0.16.0 introduced `std.Io` ("I/O as an Interface", "Cancelation", "Networking", "Juicy Main" sections of <https://ziglang.org/download/0.16.0/release-notes.html>). Libraries now take an `io: std.Io` parameter. In 0.17.1 `lib/std/Io.zig` exposes `Threaded` and an `Evented` alias that resolves to `Uring` (Linux), `Kqueue` (BSDs), `Dispatch` (Apple), or `void` elsewhere / where fiber context switching is unimplemented (<https://codeberg.org/ziglang/zig/src/tag/0.17.1/lib/std/Io.zig>).
- **Reflection shape changed in 0.17.** `@typeInfo` of structs and unions is now struct-of-arrays: `info.field_names`, `info.field_types`, `info.field_attrs` instead of `info.fields[i].name` ("Struct-Of-Arrays Style for std.lang.Type", <https://ziglang.org/download/0.17.0/release-notes.html>). Every reflection-heavy library had to be touched; code samples from before 0.17 do not compile as written.
- **`@Type` was removed in 0.16** in favour of individual type-creating builtins ("@Type Replaced with Individual Type-Creating Builtin Functions", 0.16.0 release notes). Older prior art that constructs types with `@Type` is stale.
- **`@hasDecl` only sees `pub` declarations in 0.17** ("@hasDecl Returns true Only for Public Declarations", 0.17.0 release notes). Duck-typed hooks detected by `@hasDecl` must be `pub`.
- **C interop moved out of the compiler.** `@cImport` is removed in 0.17 and `std.Build.Step.TranslateC` is deprecated in favour of the external `translate-c` package ("C Translation Moving to External Package", 0.17.0 release notes). Any library wrapping C (OpenSSL, libpq, SQLite, llhttp) now carries that package dependency.
- **Build system split.** `build.zig` now runs in a separate configurer process from the maker ("Separate the Maker Process from the Configurer Process", 0.17.0 release notes). Relevant to any design that leans on build-step code generation.

## Postgres drivers

| Project | Kind | Last push | Declared Zig | State |
|---|---|---|---|---|
| [karlseguin/pg.zig](https://github.com/karlseguin/pg.zig) | native wire protocol | 2026-11-06 | "This is for Zig 0.17.0" (README); branches for older | active, 605 stars, 8 open issues, no tagged releases |
| [lalinsky/pg.zig](https://github.com/lalinsky/pg.zig) | fork of the above ("async fork") | 2026-10-25 | follows upstream | 9 stars, 16 commits ahead / 5 behind upstream |
| [star-tek-mb/pgz](https://github.com/star-tek-mb/pgz) | native | 2024-06-11 | none declared | dormant |
| [thienpow/zpg](https://github.com/thienpow/zpg) | native | 2025-03-31 | none declared | dormant (10 days of activity) |
| [tonis2/zig-postgres](https://github.com/tonis2/zig-postgres) | libpq wrapper | 2021-10-18 | none declared | dead |
| [allyourcodebase/libpq](https://github.com/allyourcodebase/libpq) | libpq C source built with `zig build` (not a Zig API) | 2026-06-22 | `minimum_zig_version = "0.14.0"` | 16 stars; 0.17 status unverified |

### pg.zig in detail

Sources: README and `src/` at <https://github.com/karlseguin/pg.zig>.

- **Maintenance.** Single maintainer (Karl Seguin), commits within the week of the snapshot, including security-flavoured work ("auth hardening", "fix listener buffer overflow", 2026-10-22). No tagged releases and `version = "0.0.0"`; consumers pin a commit. `master` follows stable Zig; older versions live on branches.
- **I/O model.** `Pool.init(io: std.Io, allocator, opts)` and `Conn.open(io, allocator, opts)`. The pool uses `std.Io.Mutex` / `std.Io.Condition` (`src/pool.zig`). Plain TCP and Unix sockets go through `std.Io`.
- **TLS is "Experimental" and goes through OpenSSL** (README "TLS (Experimental)"), which means linking libc, `libssl`, `libcrypto`, and the `translate-c` package. The maintainer states that TLS does not work on non-blocking `std.Io` backends and that there is no fix yet: "Zig's IO implementation isn't complete yet so we're kind of stuck in this middle ground of just making it work for the most common case" (<https://github.com/karlseguin/pg.zig/issues/124>). The `lalinsky/pg.zig` fork exists to solve exactly this by swapping OpenSSL for the pure-Zig `tls.zig`.
- **Allocation model.** Per-connection read buffer (default 4096) and write buffer (default 2048) that grow temporarily; a static per-result state for up to `result_state_size` (default 32) columns, dynamic beyond it. Row values are **borrowed**: "only valid until the next call to `next()`, `deinit()` or `drain()`" unless the mapper is asked to `dupe` into the result arena or a caller allocator (README "Row", "Mapper").
- **Wire format.** Binary encoding; type mapping is strict ("you cannot use `i32` to read a `smallint` column"). Unsupported types are reachable as raw bytes (`[]u8` to read, `pg.Binary` to write).
- **Prepared statements** are cached per connection by a caller-chosen `cache_name`; once cached, the SQL text is ignored, which the README itself calls "playing with fire". There is a `describe(allocator, sql)` call returning a `QueryDescription`.
- **Comptime use is modest.** Parameters are an `anytype` tuple bound with `inline for`; `row.to(T, opts)` and `result.mapper(T, opts)` walk `@typeInfo(T).@"struct"` to map columns to fields by ordinal or by name. A build option (`column_names`) decides at build time whether column names are requested. No SQL is inspected at compile time.

  ```zig
  var result = try conn.queryOpts("select id, name from users", .{}, .{ .column_names = true });
  defer result.deinit();
  var mapper = result.mapper(User, .{});       // name -> index resolved once
  while (try mapper.next()) |user| { ... }     // user.name borrowed unless .dupe = true
  ```

- **What users report going wrong** (issue tracker):
  - Panics instead of errors on type or nullability mismatch: `Row.get` asserted and crashed the process (<https://github.com/karlseguin/pg.zig/issues/106>). The resolution, merged to master, made the default API fallible (`try row.get(...)`) with `Unsafe` variants keeping the old behaviour. Four more panic-on-bad-data bugs were filed on 2026-10-01 (#138 to #141: `infinity` timestamps, multi-dimensional and NULL arrays, enum labels, iterator type mismatch), all closed.
  - Pool and lifetime bugs: use-after-free in `Pool.initUri` (#120), segfault in pool deinit (#109), possible leaks (#99, #130), pool left fully dead after NAT idle timeout until TCP keepalive was added (#117).
  - Transactions: `ConnectionBusy` when a result is not drained before the next statement (#79, #103).
  - OpenSSL friction: header-not-found on cross-compile (#114), library path errors (#88), Windows (#78), segfaults with TLS (#91).
  - Platform compile failures after each Zig release: FreeBSD (#113, #129), Windows (#119, #121 still open).
  - Zig-version churn: issues at every release boundary (#86 for 0.15.1, #102/#108 for 0.16-dev, #147 for 0.17.0, the last being a `translate_c` hash mismatch resolved by refetching).
  - Open feature gaps: built-in JSON/JSONB deserialisation into structs (#146), row-count best practice (#154).

### libpq

No maintained Zig binding to libpq was found. `allyourcodebase/libpq` compiles the C library with the Zig build system and leaves the API to `translate-c`. It declares Zig 0.14.0 and was last pushed 2026-06-22; whether it builds on 0.17 is **unverified**. A libpq route means libc, blocking C I/O that does not participate in `std.Io` (the same class of problem pg.zig has with OpenSSL), and a C dependency in the data layer. `seemsindie/pidgn_db` (1 star, last push 2026-04-15, declares 0.16-dev) is the only found project using it.

## HTTP servers

| Project | Last push | Declared Zig | I/O model | TLS | State |
|---|---|---|---|---|---|
| `std.http.Server` | ships with Zig | 0.17.1 | caller-owned: operates on a `*std.Io.Reader` / `*std.Io.Writer` for one connection | caller's problem | standard library |
| [karlseguin/http.zig](https://github.com/karlseguin/http.zig) | 2026-10-29 | "This is for Zig 0.17.0"; `dev` branch tracks Zig master | own epoll/kqueue workers + thread pool; blocking mode on Windows | none | active, 1634 stars, 15 open issues, no tagged releases |
| [lalinsky/dusty](https://github.com/lalinsky/dusty) | 2026-11-08 | "Requires Zig 0.16 or 0.17"; CI on 0.17.1 | any `std.Io`; recommends `zio` | yes, via `tls.zig` | active, 176 stars, v0.5.0 (2026-10-25), created 2025-11 |
| [tardy-org/zzz](https://github.com/tardy-org/zzz) | 2026-11-06 | v0.3.3 on 0.17.0; `main` on 0.18-dev | own runtime `tardy` (io_uring/epoll/kqueue/poll) | yes, via `secsock` | 797 stars, self-described **alpha**, MPL-2.0 |
| [zigzap/zap](https://github.com/zigzap/zap) | 2026-09-06 | 0.16.0 | wraps C library facil.io | via facil.io | **archived** 2026-09; 3402 stars |
| [technologylab-ai/baz](https://github.com/technologylab-ai/baz) + `bounded-http` | 2026-10-04 | `minimum_zig_version = "0.17.0"` | pure Zig (details unverified) | unverified | zap's named successor; 47 and 12 stars, created 2026-09 |
| [zon-dev/zinc](https://github.com/zon-dev/zinc) | 2026-09-20 | 0.16.0 | own `aio` | unverified | 188 stars, beta; 0.17 not declared |
| [muhammad-fiaz/httpx.zig](https://github.com/muhammad-fiaz/httpx.zig) | 2026-11-08 | 0.17.0 | unverified | claims HTTP/1 to 3 | 112 stars, created 2026-01; claims not examined |

### std.http.Server

Source: <https://codeberg.org/ziglang/zig/src/tag/0.17.1/lib/std/http/Server.zig> (809 lines). Its own doc comment: "Handles a single connection lifecycle." It is constructed from a reader and a writer (`Server.init(in: *Reader, out: *Writer)`), and `receiveHead()` returns a `Request`. The header must fit in the reader's buffer. It has no accept loop, routing, connection limits, timeouts, or pooling; the caller supplies all of them, which also means it runs on whatever `std.Io` the caller uses. The http.zig README asserts "`std.http.Server` is very slow and assumes well-behaved clients" (<https://github.com/karlseguin/http.zig#why-not-stdhttpserver>); that is a competitor's claim and is **unverified** for 0.17. `h0rv/zchema` (below) is built directly on it.

### http.zig in detail

Sources: README and `src/` at <https://github.com/karlseguin/http.zig>.

- **Maintenance.** Same single maintainer as pg.zig; recent commits are HTTP-compliance hardening from outside contributors (absolute-form targets, malformed hosts, 1xx/204/304 bodies). Jetzig and Tokamak are built on it (README "Alternatives"); `ziex` uses a fork.
- **I/O model.** `Server(H).init(io, allocator, config, handler)` takes an `io`, but the server still owns its concurrency: worker threads accept and parse over non-blocking sockets with epoll or kqueue, then hand requests to a `std.Thread`-based pool where application code runs (README "Configuration"; `src/worker.zig`, `src/thread_pool.zig`). On Windows it falls back to a blocking thread-per-connection mode. The maintainer's position on moving to `std.Io` (<https://github.com/karlseguin/http.zig/issues/175>, open since 2025-11): exposing an `Io` to handlers is straightforward, replacing the workers and pool is "less straightforward", and it depends on a complete green-thread implementation on Linux, macOS, and Windows.
- **Allocation model.** `req.arena` / `res.arena` are a configurable thread-local buffer that falls back to an arena; memory lives until the response is written. Minimum memory is a documented formula: `thread_pool.count * thread_pool.buffer_size + workers.count * workers.large_buffer_count * workers.large_buffer_size + workers.count * workers.min_conn * request.buffer_size`.
- **No TLS**, by decision, until the standard library has a TLS server (<https://github.com/karlseguin/http.zig/issues/148>). The README of Tokamak accordingly says it is "not designed to be used alone, but with a reverse proxy in front of it".
- **Comptime use.** The server is generic over an application handler type and discovers optional hooks by name:

  ```zig
  if (comptime std.meta.hasFn(Handler, "dispatch")) { ... }      // also "handle", "notFound", "uncaughtError", "afterInit"
  const has_websocket = Handler != void and @hasDecl(Handler, "WebsocketHandler");
  ```

  Routes are registered at runtime (`router.get("/api/user/:id", getUser, .{})`), so the route table is not comptime data.
- **What users report going wrong.**
  - Concurrency and shutdown defects: connections stuck in `CLOSE_WAIT` exhausting the thread pool (#226), intermittent `SIGABRT` (#196), race conditions (#125, open), `listenInNewThread` instability (#144), `deinit` on macOS (#223), memory issues under `ReleaseFast` with a custom dispatcher (#169), memory growth under high concurrency (#176), hangs (#209, #210).
  - Windows: service kill (#182, open), link and build failures (#194, #206, #207).
  - Long-lived requests occupy pool threads; SSE and streaming need workarounds (#174, #179). Streaming multipart upload is an open request (#158).
  - Body silently empty without `Content-Length` (#170, open).
  - Zig-version churn: #145, #151, #156, #162, #167, #206.

### dusty in detail

Sources: README and `src/extract.zig` at <https://github.com/lalinsky/dusty>.

- Written against `std.Io`; "runs on any `std.Io` implementation that supports networking, including `std.Io.Threaded`". The author also maintains `zio` (699 stars, an `std.Io` implementation with stackful coroutines over io_uring/epoll/kqueue/IOCP, <https://github.com/lalinsky/zio>) and recommends it for production.
- Parses HTTP with **llhttp**, the C parser from Node.js, so it carries a C dependency. TLS and gzip via the author's own `tls.zig` and `zlib.zig`.
- Timeouts and connection limits "on by default"; README claims HTTP Garden request-smuggling checks and a high HttpArena ranking (**unverified**).
- Comptime use: handlers declare what they need by parameter type, including marker types that carry a comptime name:

  ```zig
  fn hello(app: *App, name: http.Param("name", []const u8), res: *http.Response) !void { ... }
  ```

- Risk profile: one year old, pre-1.0 (v0.5.0), single maintainer, 22 open issues that are mostly the maintainer's own backlog (HTTP/2 #38, typed forms #305, `req.json` ignoring `Content-Type` #320, repeated query parameters keeping only the last value #319). Sparse third-party issue history means little independent evidence either way.

### zzz, zap, and the rest

- **zzz** depends on its own async runtime, `tardy`, rather than `std.Io`; the open thread on adopting the new I/O interface is <https://github.com/tardy-org/zzz/issues/62>. The README labels it alpha. Users hit build errors following the getting-started guide (#23, #24) and missing features (multipart #41, WebSocket #55, per-route middleware #61). MPL-2.0 licensed, unlike the MIT norm elsewhere.
- **zap** was the most-starred Zig HTTP project and is now archived; its README points to `baz` on `bounded-http`, both two months old. Lesson recorded by the event itself: a wrapper around a C event loop (facil.io) did not survive the `std.Io` transition.

## ORMs and query builders

| Project | Last push | Declared Zig | Backend | Technique | State |
|---|---|---|---|---|---|
| [jetzig-framework/jetquery](https://github.com/jetzig-framework/jetquery) | 2026-01-22 | 0.15.1 | Postgres via pg.zig | comptime SQL rendering, type-state builder, schema file generated by reflecting a live DB | 63 stars; not on 0.16/0.17 |
| [cztomsik/fridge](https://github.com/cztomsik/fridge) | 2026-11-10 | 0.17.1 | **SQLite only** ("Additional drivers (e.g., PostgreSQL)" unchecked) | generic `Query(T)` with comptime column names; runtime SQL building | 95 stars; README warns of ongoing breaking changes |
| [vrischmann/zig-sqlite](https://github.com/vrischmann/zig-sqlite) | 2026-11-06 | 0.17.0 | SQLite | comptime parsing of the SQL string for bind markers | 625 stars, mature (since 2020) |
| [nektro/zig-zorm](https://github.com/nektro/zig-zorm) | 2026-10-21 | 0.17.0 | unverified | "ORM-ish" | 15 stars, zigmod-based |
| [Tony-ArtZ/zorm](https://github.com/Tony-ArtZ/zorm) | 2026-04-26 | 0.14.0 | Postgres, MySQL | custom schema language | 40 stars; external schema language is out of scope for this effort |
| [senet-toolbox/pg-orm](https://github.com/senet-toolbox/pg-orm), [Alarak-Alex/zgorm](https://github.com/Alarak-Alex/zgorm), [SOG-web/fluentorm.zig](https://github.com/SOG-web/fluentorm.zig), others | 2026 | 0.15 to 0.17 | Postgres (mostly via pg.zig) | various | 0 to 2 stars each; not examined |

### JetQuery

Sources: README and `src/jetquery/Query.zig`, `sql/Where.zig`, `reflection/Reflect.zig` at <https://github.com/jetzig-framework/jetquery>.

- **Declaration.** A `Schema` struct whose declarations are `Model(Schema, "table", struct { ...columns }, .{ .relations = ... })`. The schema file is normally *generated* by connecting to the database and reflecting it (`Reflect(...).generateSchema()` writes Zig source), so the database, not the Zig declaration, is the source of truth.
- **Comptime SQL.** Every builder call returns a *new type*; the accumulated query lives in comptime parameters, and the SQL string is a comptime field:

  ```zig
  fn Statement(Adapter: type, comptime query_context: sql.QueryContext, Schema: type, Model: type,
               comptime options: StatementOptions(query_context)) type {
      return struct {
          values: jetquery.fields.FieldValues(Model, options.relations, options.field_infos),
          comptime sql: []const u8 = render(),   // rendered entirely at comptime
          ...
  ```

  Only bound values exist at runtime. The `where` argument is an anonymous tuple DSL (`.{ .{ .age, .gt, 4 }, .OR, .{ .name = "x" } }`) decoded by `@typeInfo` in a 1,100-line `Where.zig`, with `@compileError` for bad shapes (44 `@compileError` sites across the query code) and `@setEvalBranchQuota(10000)` in several places.
- **Consequence for runtime-shaped queries.** Because the query shape is the type, a filter whose *structure* comes from an HTTP request cannot be expressed in the typed builder; raw SQL fragments (`.{ "age / paws = ? or age * paws < ?", .{ 2, 10 } }`) are the escape hatch. This is the exact gap listed in the parent issue as "expression and filter language: typed at build time, yet buildable from runtime requests".
- **State.** Declares Zig 0.15.1; last commit 2026-01-22 ("Fix some writergate related stuff"); CI workflows disabled 2025-12-22. Its pg.zig pin is from the 0.15 era. **Not usable on 0.17 as published.**
- **User reports.** `insert` returning `void` with `returning()` existing but undocumented (#19); migrations that add and drop columns produce a syntax error (#18); no check for column names clashing with relation names (#12); UUID primary keys in migrations (#4); no documented way to serialise results to JSON (#5).

### fridge

Sources: README and `src/query.zig` at <https://github.com/cztomsik/fridge>. Same author as Tokamak.

- `Query(comptime T: type)` gives column-checked methods by taking the column name as a comptime string and computing the value type from it:

  ```zig
  pub fn where(self: Q, comptime col: []const u8, val: util.ColType(T, col)) Q
  pub fn orderBy(self: Q, col: std.meta.FieldEnum(T), ord: enum { asc, desc }) Q
  ```

  The builder itself is a runtime value (SQL is assembled at runtime in a session arena), so conditional composition is ordinary code: `maybeWhere("role", filter.role)`, `ifWhere(cond, "age", filter.age)`. A `.raw` switch drops to untyped SQL.
- Session wraps a connection plus an arena; `pool.getSession(allocator)` takes a per-request allocator.
- Migrations are declarative: diff a DDL file against the live SQLite schema. SQLite only.
- Useful as a contrast to JetQuery (comptime *checking* with runtime *building*), not as a Postgres candidate.

### zig-sqlite

Source: README "Comptime checks" at <https://github.com/vrischmann/zig-sqlite>. The SQL string is a comptime parameter; the library parses it at compile time to count bind markers and, with an extended marker syntax (`?{usize}`), to type-check bound values:

```zig
var stmt = try db.prepare("SELECT id FROM user WHERE age > ? AND weight > ?{usize}");
// binding a bool to the second marker fails:
// error: value type bool is not the bind marker type usize
```

The README shows the resulting error: a short message followed by a chain of "called from here" notes through library internals. The check is on parameters only; it knows nothing about tables or result columns.

## Web frameworks

| Project | Last push | Declared Zig | Built on | State |
|---|---|---|---|---|
| [jetzig-framework/jetzig](https://github.com/jetzig-framework/jetzig) | 2026-06-12 | `0.15.0-dev` | http.zig, jetquery, zmpl | 1520 stars, 40 open issues; not on 0.16/0.17 |
| [cztomsik/tokamak](https://github.com/cztomsik/tokamak) | 2026-11-10 | 0.17.1 | http.zig (`dev` branch pin) | 646 stars, 5 open issues, active |
| [nevindra/nilo](https://github.com/nevindra/nilo) | 2026-11-02 | 0.17.0 (from v0.8.0) | zio, a pg.zig fork, llhttp | 13 stars, created 2026-08-10, effectively one author |
| [h0rv/zchema](https://github.com/h0rv/zchema) | 2026-11-03 | 0.17.0 | `std.http.Server` | 4 stars, created 2026-06 |
| [ziex-dev/ziex](https://github.com/ziex-dev/ziex) | 2026-11-05 | 0.17.0 | http.zig fork | 420 stars; full-stack/JSX-like, outside this effort's domain |

### Jetzig

Sources: <https://github.com/jetzig-framework/jetzig> `build.zig` and issue tracker.

- **Technique: build-step code generation.** `build.zig` compiles and runs helper executables that scan the application's `src/app/views` tree and emit a `routes.zig` module, which is then imported by the real executable (`exe_routes_file` ... `addOutputFileArg("routes.zig")`); templates (zmpl) are likewise compiled into `.zig` files. Convention-over-configuration is implemented by generators rather than by comptime.
- **State.** The default branch declares `0.15.0-dev`; the tracking issue for newer Zig (<https://github.com/jetzig-framework/jetzig/issues/231>) reports 0.15.2 passing as of 2026-01. No 0.16 or 0.17 support was found. Activity in 2026 is sparse.
- **User reports.** Build failures against the stated Zig version (#238, #217 "type 'u29' has no members"), Windows cannot serve requests on the 0.15 branch (#236), project generator failures (#226, #237), cookie parsing broken (#246), no tagged versions (#139), and an open request for OpenAPI support (#137). The pattern: a multi-package, generator-heavy framework has many places for a Zig upgrade to break, and fell two releases behind.

### Tokamak

Sources: README, `src/route.zig`, `src/schema.zig`, `src/middleware/swagger.zig` at <https://github.com/cztomsik/tokamak>.

- **Handler-signature reflection plus dependency injection.** A route is built at comptime from a path and a plain function. The path's `:params`, an optional trailing `?` (query struct), and whether the method has a body determine how the function's parameters are split into injected dependencies, path params, query, and body:

  ```zig
  fn routeMetadata(comptime path, comptime has_query, comptime has_body, comptime handler) *const Route.Metadata {
      const field_types = std.meta.fieldTypes(std.meta.ArgsTuple(@TypeOf(handler)));
      const n_params = std.mem.countScalar(u8, path, ':');
      const n_deps = field_types.len - n_params - @intFromBool(has_query) - @intFromBool(has_body);
      return &.{ .deps = ..., .params = ..., .query = ..., .body = ...,
                 .result = .schema(R), .errors = <names from the handler's error set> };
  }
  ```

  The handler's *error set* is reflected too and becomes the documented error responses. `Route.router(T)` turns a struct whose `pub fn` names look like `"GET /path"` into a route list.
- **Type to JSON Schema at comptime.** `Schema.schema(comptime T)` is a `union(enum)` value built by switching on `@typeInfo(T)`, using the 0.17 struct-of-arrays reflection (`s.field_names, s.field_types, s.field_attrs`), with a `jsonSchema` declaration as a per-type override and `@compileError("Unsupported type " ++ @typeName(T))` otherwise.
- **OpenAPI is assembled at request time** from that comptime metadata: the swagger handler walks `[]const Route` and serialises an OpenAPI 3.0.0 document on each call. The *facts* are comptime; the *document* is not a build artefact. Unions are a TODO (`.@"union" => .{ .object = &.{} }`).
- **I/O and allocation.** Inherits http.zig's model; handlers get a request-scoped arena by asking for `std.mem.Allocator`.
- **State and reports.** Tracks stable promptly (bumped to 0.17.1 on the snapshot date) and **skipped 0.16 entirely** because of compile errors (<https://github.com/cztomsik/tokamak/issues/51>). No tags or releases. Open gaps: error handler (#23), custom responders (#30), form data (#9). The README lists a steady stream of renames and removed features; it removed optional dependency injection as "undocumented, incomplete, subtly broken".

### nilo

Sources: README and `refusals/README.md` at <https://github.com/nevindra/nilo>. Closest in spirit to this effort: "A plain function is a route. A plain struct is a table."

- A table is a struct with a `pub const nilo_table = .{ .name, .key, .unique, .references }` declaration; queries take an anonymous-struct filter (`.where = .{ .age = .{ .gt = 18 } }`) "checked against your struct while compiling"; the README says migrations are generated from a diff without a database, and that routing, errors, OpenAPI, and SQL "all read the same struct". These are the project's claims; the implementation was **not examined in depth**.
- **Compile errors as a tested deliverable.** A `refusals/` directory holds programs that must fail to compile with a specific nilo-authored message, checked by `zig build test` (README badge: 620 such cases). Example message from the README: ``error: nilo: User has no column `agee`, asked for in a condition. Did you mean `age`?``
- **Caveats.** Three months old, 13 stars, 275 of roughly 293 commits by one author, 342 KB `build.zig`, depends on its own forks of pg.zig and tls.zig. Evidence of real-world use: none found. It is a source of ideas, not a dependency candidate.

### zchema

Sources: README at <https://github.com/h0rv/zchema>. "A thin layer over `std.http.Server`" that adds JSON body parsing, JSON Schema (Draft 2020-12) validation, and OpenAPI **3.1** generation, explicitly modelled on FastAPI/Pydantic. Handler parameters use marker types (`z.Body(T)`, `z.Path(T)`, `z.Query(T)`, `z.Header("name")`) and return types encode status (`z.Created(T)`, `!?T` meaning 200 or 404). It does not own the accept loop or threading. 4 stars, five months old.

## JSON and OpenAPI tooling

- **`std.json`** (standard library) parses into and serialises from Zig types by reflection, with `jsonStringify` / `jsonParse` declarations as per-type hooks. Tokamak, http.zig (`res.json`), and zchema all use it rather than a third-party library. No evidence was found of a maintained alternative with meaningful adoption: `getty-zig/getty` is archived (last push 2024-12), `getty-zig/json` last pushed 2024-06. `OrlovEvgeny/serde.zig` (94 stars, pushed 2026-10-18) and `EzequielRamis/zimdjson` (176 stars, a simdjson port, pushed 2026-04) exist; neither was examined.
- **OpenAPI, server side (types to spec).** Only inside frameworks: Tokamak (3.0.0, at request time), zchema (3.1), nilo, and `Kludex/zapi` (2 stars, single day of commits). There is no standalone, adopted "Zig types to OpenAPI" library.
- **OpenAPI, client side (spec to Zig).** `christianhelle/openapi2zig` (24 stars, on 0.17.1) generates Zig clients and models from a spec. Opposite direction from this effort; relevant only as a tool for testing a derived spec.
- **JSON Schema.** `h0rv/jsonschema.zig` (2 stars, 0.17.0) generates schemas from Zig types and validates; `WhiskeyTuesday/zig-jsonschema` (2 stars) validates. Neither has adoption.

## Candidates to wrap

Facts and trade-offs only; the choice is made later.

### Postgres data layer

| Option | For | Against |
|---|---|---|
| **pg.zig** | Only maintained, adopted native driver; on 0.17.0 within days of release; binary protocol; pool; `describe`; LISTEN/NOTIFY; takes `std.Io`; MIT | Single maintainer; no releases or version numbers (pin a commit); TLS is "Experimental", needs OpenSSL + libc + translate-c, and fails on non-blocking `std.Io` backends (#124); borrowed row memory needs a copy policy; a history of panics on unexpected data, now mostly converted to errors; prepared-statement cache keyed by caller-supplied name |
| **lalinsky/pg.zig fork** | Fixes the TLS/non-blocking problem with pure-Zig `tls.zig`; same API lineage; pairs with dusty/zio | 9 stars; a fork that must track upstream (5 commits behind at snapshot); second single maintainer; adds `xsync` and forked `metrics` dependencies |
| **libpq via allyourcodebase/libpq** | The reference client: every auth method, TLS, protocol feature | C dependency and libc; blocking I/O outside `std.Io`; no Zig-level API exists, so the adapter would write one; declares Zig 0.14, 0.17 unverified |
| **Own wire-protocol implementation** | No dependency; I/O and allocation model chosen to fit | Reimplements auth (SCRAM), TLS negotiation, type codecs, pooling: the bug classes visible in pg.zig's tracker |

Cross-cutting facts: nothing in the Zig ecosystem checks SQL against a schema at compile time for Postgres; pg.zig does no comptime SQL work, so all derivation would live in the framework. JetQuery and nilo both chose pg.zig (or a fork) underneath.

### HTTP adapter

| Option | For | Against |
|---|---|---|
| **http.zig** | Most adopted; proven under Jetzig and Tokamak; on 0.17.0; documented memory model; MIT | Own event loop and `std.Thread` pool, not `std.Io` (#175 open a year); no TLS, reverse proxy assumed; blocking fallback on Windows; a tracker with recurring concurrency and shutdown defects; no releases; runtime route table |
| **dusty** | Built on `std.Io`, so it shares one I/O model with an `std.Io` Postgres client; TLS; timeouts and limits by default; on 0.16 and 0.17; versioned releases | One year old, pre-1.0; single maintainer; C dependency (llhttp); "recommended" runtime is the same author's `zio`; little independent issue history |
| **std.http.Server** | No dependency at all; follows Zig releases by definition; runs on any `std.Io` | Per-connection state machine only: the adapter must supply accept loop, concurrency, limits, timeouts, routing; performance and robustness against hostile clients disputed by http.zig's author (unverified on 0.17) |
| **zzz** | TLS; several backends; fast by its own benchmarks | Self-described alpha; own runtime instead of `std.Io`; MPL-2.0 |

Cross-cutting facts: the Postgres and HTTP choices interact through the I/O model. http.zig (threads) with pg.zig (blocking sockets under `std.Io.Threaded`) is the combination with the longest track record. dusty with the pg.zig fork under `zio` is the combination designed for `std.Io` evented backends, with the shortest track record. Mixing an evented HTTP server with upstream pg.zig TLS is the combination known to break (#124). A thin adapter boundary would let the HTTP side be swapped; zchema shows a derivation layer that stays independent of the server loop.

## Comptime techniques: borrow or avoid

### Worth borrowing

1. **Reflect the handler/function signature, including its error set** (Tokamak `routeMetadata`). Parameter types yield path, query, and body schemas; the inferred error set yields the documented failure responses. Cheap, zero annotation, and stays in sync by construction.
2. **A comptime-built schema value with a per-type override hook** (Tokamak `Schema.schema(T)` plus `jsonSchema`; `std.json`'s `jsonStringify`). A plain tagged union that is ordinary data at comptime and can also be serialised.
3. **Comptime column names with a computed value type** (fridge `where(comptime col: []const u8, val: ColType(T, col))`). Type-checks the column and the value while leaving the query a runtime value, so request-driven composition (`maybeWhere`, `ifWhere`) stays ordinary code.
4. **Marker types that carry meaning in the type** (dusty `Param("name", T)`; zchema `Body(T)`, `Query(T)`, `Created(T)`, `!?T` as 200-or-404). The same type drives extraction and documentation.
5. **Render SQL at comptime when the shape is static** (JetQuery `comptime sql: []const u8 = render()`). For a closed world of declared actions, statement text can be a constant with only values bound at runtime.
6. **Compile errors as a tested artefact** (nilo `refusals/`): one deliberately wrong program per diagnostic, asserted by the build. Directly serves the "compile-error quality is a first-class constraint" note in the parent issue.
7. **Declaration by a well-known `pub const` on the struct** (nilo `nilo_table`, Tokamak `jsonSchema`). Note the 0.17 rule: such declarations must be `pub` to be visible to `@hasDecl`.
8. **Build options that remove code paths** (pg.zig `column_names`, http.zig `httpz_blocking`) rather than runtime flags.

### Worth avoiding, or adopting with eyes open

1. **Type-state builders where each call returns a new type** (JetQuery). The query shape must be comptime-known, so request-driven filters fall back to raw SQL; errors surface deep inside generic instantiations; `@setEvalBranchQuota` raises are needed; and every Zig reflection change (0.16 `@Type` removal, 0.17 struct-of-arrays) hits the densest code. JetQuery is two Zig releases behind.
2. **Anonymous-tuple DSLs decoded by `@typeInfo`** (JetQuery `where(.{ .{ .age, .gt, 4 }, .OR, ... })`). Compact to write, but the grammar is implicit, needs a large hand-written decoder, and a malformed tuple produces errors that describe the decoder, not the user's mistake.
3. **Raw `@compileError` from inside library internals.** zig-sqlite's own README shows the result: a one-line message followed by "called from here" notes through library frames. Good messages need the check hoisted to the user-facing entry point and phrased in the user's terms (nilo's approach).
4. **Positional conventions inferred from parameter order** (Tokamak: dependencies first, then path params, then query, then body, determined by counting `:` in the path). Terse, but a reordered parameter silently changes meaning; marker types (item 4 above) make the same information explicit.
5. **Duck-typed optional hooks by name** (http.zig `hasFn(Handler, "notFound")`). A misspelled or non-`pub` hook is silently ignored; 0.17's `@hasDecl` change made more of these silent.
6. **Generating the schema from a live database** (JetQuery `Reflect`). Inverts the source of truth and needs a database at build time; contrary to "the domain is declared in Zig".
7. **Multi-executable build-step generation as the core mechanism** (Jetzig routes and templates). It works, but it multiplied the surface that broke on each Zig release, and 0.17 changed the build runner architecture again. Where code generation is used, a small single-purpose generator is the lower-risk shape.
8. **Assembling derived documents at request time** (Tokamak's OpenAPI handler). Not runtime reflection in the strict sense, since the inputs are comptime constants, but the document is rebuilt per request instead of being a build artefact or comptime string.
9. **Panicking on data that disagrees with the declared type** (pg.zig before the `safe_mode` change, #106). In a derived system, a schema drift between the model and the database would otherwise crash the process; pg.zig reversed this default after user pressure.
10. **Depending on a C library for I/O-bearing work** (zap on facil.io, pg.zig TLS on OpenSSL). Both collided with the `std.Io` transition: one project was archived, the other has an open, unfixable-for-now issue.

## Not verified

- Whether any listed project actually builds and passes tests on Zig 0.17.1 (declarations only).
- All performance and benchmark claims.
- Internals of nilo, baz/bounded-http, zinc, httpx.zig, serde.zig, zimdjson, and the sub-10-star ORMs.
- `std.http.Server` performance and hostile-client behaviour on 0.17.
- Whether `allyourcodebase/libpq` builds on 0.17.
- Production usage of any library beyond authors' own statements.

## Sources

- Zig releases: <https://ziglang.org/download/index.json>, <https://ziglang.org/download/0.17.0/release-notes.html>, <https://ziglang.org/download/0.16.0/release-notes.html>
- Zig standard library at tag 0.17.1: <https://codeberg.org/ziglang/zig/src/tag/0.17.1/lib/std/http/Server.zig>, <https://codeberg.org/ziglang/zig/src/tag/0.17.1/lib/std/Io.zig>
- pg.zig: <https://github.com/karlseguin/pg.zig>; issues [#106](https://github.com/karlseguin/pg.zig/issues/106), [#124](https://github.com/karlseguin/pg.zig/issues/124), [#147](https://github.com/karlseguin/pg.zig/issues/147), and the tracker at <https://github.com/karlseguin/pg.zig/issues?q=is%3Aissue>; fork <https://github.com/lalinsky/pg.zig>
- http.zig: <https://github.com/karlseguin/http.zig>; issues [#148](https://github.com/karlseguin/http.zig/issues/148), [#175](https://github.com/karlseguin/http.zig/issues/175), and the tracker
- dusty: <https://github.com/lalinsky/dusty>; zio: <https://github.com/lalinsky/zio>
- zzz: <https://github.com/tardy-org/zzz>, [#62](https://github.com/tardy-org/zzz/issues/62); tardy: <https://github.com/tardy-org/tardy>
- zap: <https://github.com/zigzap/zap>; baz: <https://github.com/technologylab-ai/baz>; bounded-http: <https://github.com/technologylab-ai/bounded-http>
- Jetzig: <https://github.com/jetzig-framework/jetzig>, [#231](https://github.com/jetzig-framework/jetzig/issues/231); JetQuery: <https://github.com/jetzig-framework/jetquery>, [#19](https://github.com/jetzig-framework/jetquery/issues/19)
- Tokamak: <https://github.com/cztomsik/tokamak>, [#51](https://github.com/cztomsik/tokamak/issues/51); fridge: <https://github.com/cztomsik/fridge>
- zig-sqlite: <https://github.com/vrischmann/zig-sqlite>
- nilo: <https://github.com/nevindra/nilo>; zchema: <https://github.com/h0rv/zchema>; jsonschema.zig: <https://github.com/h0rv/jsonschema.zig>
- libpq port: <https://github.com/allyourcodebase/libpq>; openapi2zig: <https://github.com/christianhelle/openapi2zig>
- Other repositories in the tables are linked inline; their rows are GitHub API metadata only.
