# Library compile check

Throwaway program for the ticket "Compile check for pg.zig and http.zig on Zig 0.17.1" (issue #15). Never merged.

Builds `karlseguin/pg.zig` and `karlseguin/http.zig` at pinned commits on Zig 0.17.1, opens a pg.zig pool, and serves `GET /users?min_power=N` from http.zig. The handler runs one parameterised query and copies each row out of the driver's memory into the response arena before serialising JSON.

## Run

Needs a Postgres reachable on `127.0.0.1:54329` as user `postgres` with trust authentication (edit `src/main.zig` to change it).

```sh
zig build
./zig-out/bin/spike
curl 'http://localhost:8811/users?min_power=9000'
```

## Pinned commits

- pg.zig `a9fb17023e2f534dd1712628c80eaa9a551473a5` (2026-11-06)
- http.zig `1bb71ff128a044b1645df91046473c38abbf965c` (2026-10-29)
