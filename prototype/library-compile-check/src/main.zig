const std = @import("std");
const pg = @import("pg");
const httpz = @import("httpz");

const App = struct {
    pool: *pg.Pool,
    main_thread: std.Thread.Id,
};

const User = struct { id: i32, name: []const u8 };

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const pool = try pg.Pool.init(io, allocator, .{
        .size = 4,
        .connect = .{ .port = 54329, .host = "127.0.0.1" },
        .auth = .{ .username = "postgres", .database = "postgres", .timeout = 10_000 },
    });
    defer pool.deinit();

    _ = try pool.exec("drop table if exists spike_users", .{});
    _ = try pool.exec("create table spike_users (id integer primary key, name text not null, power integer not null)", .{});
    _ = try pool.exec("insert into spike_users values (1, 'Leto', 9001), (2, 'Duncan', 100), (3, 'Ghanima', 9500)", .{});

    var app: App = .{ .pool = pool, .main_thread = std.Thread.getCurrentId() };

    var server = try httpz.Server(*App).init(io, allocator, .{ .address = .localhost(8811) }, &app);
    defer server.deinit();
    defer server.stop();

    var router = try server.router(.{});
    router.get("/users", users, .{});

    std.debug.print("listening http://localhost:8811/\n", .{});
    try server.listen();
}

fn users(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const query = try req.query();
    const min_power = try std.fmt.parseInt(i32, query.get("min_power") orelse "0", 10);

    var result = try app.pool.query("select id, name from spike_users where power > $1 order by id", .{min_power});
    defer result.deinit();

    var list: std.ArrayList(User) = .empty;
    while (try result.next()) |row| {
        const name = try row.get([]const u8, 1); // driver memory: valid until next()
        try list.append(res.arena, .{
            .id = try row.get(i32, 0),
            .name = try res.arena.dupe(u8, name), // copied out
        });
    }

    try res.json(.{
        .on_main_thread = std.Thread.getCurrentId() == app.main_thread,
        .users = list.items,
    }, .{});
}
