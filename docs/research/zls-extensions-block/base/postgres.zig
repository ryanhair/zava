//! PROTOTYPE, throwaway. One extension. It imports the kernel; the kernel never imports it.
const std = @import("std");
const zava = @import("zava");

pub const name = "postgres";
const Self = @This();

// ---- 1. its own typed options, for a resource and for an attribute

pub const AttributeOptions = struct { column: ?[]const u8 = null };

pub fn Options(comptime R: type) type {
    return struct {
        table: []const u8,
        attributes: zava.PerAttribute(R, AttributeOptions) = .{},
    };
}

// ---- 2. what it normalizes them to (plain data, readable at runtime)

pub const Column = struct { attribute: []const u8, name: []const u8, sql_type: []const u8, nullable: bool };
pub const Table = struct { name: []const u8, primary_key: []const u8, columns: []const Column };
/// Null: the resource is not persisted by this extension.
pub const Lowered = ?Table;

fn sqlType(comptime T: type) ?[]const u8 {
    return switch (T) {
        i64 => "bigint",
        i32 => "integer",
        bool => "boolean",
        []const u8 => "text",
        else => switch (@typeInfo(T)) {
            .optional => |o| sqlType(o.child),
            else => null,
        },
    };
}

pub fn lower(comptime R: type, comptime res: zava.Resource, comptime decl: ?Options(R)) Lowered {
    const d = decl orelse return null;
    var columns: [res.attributes.len]Column = undefined;
    for (res.attributes, 0..) |a, i| {
        const T = @FieldType(R, a.name);
        const column = @field(d.attributes, a.name).column orelse a.name;
        for (columns[0..i]) |c| if (std.mem.eql(u8, c.name, column))
            @compileError("postgres: resource '" ++ res.name ++ "': attributes '" ++ c.attribute ++ "' and '" ++ a.name ++ "' both map to column '" ++ column ++ "'");
        columns[i] = .{
            .attribute = a.name,
            .name = column,
            .sql_type = sqlType(T) orelse
                @compileError("postgres: resource '" ++ res.name ++ "': attribute '" ++ a.name ++ "' has type '" ++ a.zig_type ++ "', which has no Postgres mapping"),
            .nullable = a.optional,
        };
    }
    const c = columns;
    var pk: []const u8 = undefined;
    for (c) |col| {
        if (std.mem.eql(u8, col.attribute, res.primary_key)) pk = col.name;
    }
    return .{ .name = d.table, .primary_key = pk, .columns = &c };
}

// ---- 3. comptime derivations: values and behaviour

fn columnOf(comptime t: Table, comptime attribute: []const u8) []const u8 {
    for (t.columns) |c| if (std.mem.eql(u8, c.attribute, attribute)) return c.name;
    unreachable;
}

pub fn sql(comptime R: type, comptime action: []const u8) ?[]const u8 {
    comptime {
        const t = zava.options(Self, R) orelse return null;
        const a = for (zava.resource(R).actions) |a| {
            if (std.mem.eql(u8, a.name, action)) break a;
        } else unreachable;
        var s: []const u8 = "";
        switch (a.kind) {
            .create => {
                var values: []const u8 = "";
                for (a.accept, 0..) |f, i| {
                    s = s ++ (if (i > 0) ", " else "") ++ columnOf(t, f);
                    values = values ++ (if (i > 0) ", " else "") ++ std.fmt.comptimePrint("${d}", .{i + 1});
                }
                return "insert into " ++ t.name ++ " (" ++ s ++ ") values (" ++ values ++ ") returning *";
            },
            .read => {
                for (a.accept, 0..) |f, i| s = s ++ (if (i > 0) " and " else "") ++ columnOf(t, f) ++ std.fmt.comptimePrint(" = ${d}", .{i + 1});
                return "select * from " ++ t.name ++ (if (a.accept.len > 0) " where " ++ s else "");
            },
            else => return null,
        }
    }
}

/// Contributes a derived value to the doc comment of a kernel-generated action.
pub fn actionDoc(comptime R: type, comptime action: []const u8) ?[]const u8 {
    return sql(R, action);
}

// ---- 4. descriptions: developer-facing types and functions the kernel emitter writes

/// A type the extension wrote itself; descriptions may name it.
pub const Limit = struct { count: u32 = 50 };

pub fn describe(comptime R: type) []const zava.Description(Self) {
    comptime {
        const t = zava.options(Self, R) orelse return &.{};
        const res = zava.resource(R);
        var tags: [t.columns.len][]const u8 = undefined;
        for (t.columns, 0..) |c, i| tags[i] = c.attribute;
        const tg = tags;
        return &.{
            .{ .@"struct" = .{
                .name = "PrimaryKey",
                .doc = "Identifies one `" ++ res.name ++ "` in table `" ++ t.name ++ "`.",
                .fields = &.{.{ .name = res.primary_key[0..res.primary_key.len :0], .type = .{ .type = @FieldType(R, res.primary_key) } }},
            } },
            .{ .@"enum" = .{ .name = "SortBy", .doc = "Attributes of `" ++ res.name ++ "` that have a column.", .tags = &tg } },
            .{ .function = .{
                .name = "get",
                .doc = "Fetches one `" ++ res.name ++ "` by primary key. SQL: `select * from " ++ t.name ++ " where " ++ t.primary_key ++ " = $1`",
                .params = &.{.{ .name = "pk", .type = .{ .described = "PrimaryKey" } }},
                .returns = .{ .type = ?R },
                .delegate = .get,
            } },
            .{ .function = .{
                .name = "listSql",
                .doc = "The SQL that lists `" ++ res.name ++ "` records in the given order.",
                .params = &.{ .{ .name = "sort", .type = .{ .described = "SortBy" } }, .{ .name = "limit", .type = .{ .type = Limit } } },
                .returns = .{ .type = []const u8 },
                .delegate = .listSql,
            } },
        };
    }
}

/// Comptime behaviour, typed on a generated type by lookup.
pub fn get(comptime R: type, pk: zava.Generated(R, "PrimaryKey")) ?R {
    const t = comptime zava.options(Self, R).?;
    std.debug.print("  [postgres] select * from {s} where {s} = {any}\n", .{ t.name, t.primary_key, pk });
    return null;
}

pub fn listSql(comptime R: type, sort: zava.Generated(R, "SortBy"), limit: Limit) []const u8 {
    const t = comptime zava.options(Self, R).?;
    _ = limit;
    return switch (sort) {
        inline else => |s| comptime "select * from " ++ t.name ++ " order by " ++ columnOf(t, @tagName(s)),
    };
}

// ---- 5. build-run code: the model as runtime data, writing files nothing compiles

pub const commands = struct {
    /// `postgres.migrate <dir>`: diffs the model against `<dir>/snapshot.txt` and writes the next migration.
    pub fn migrate(ctx: zava.Command(Self)) !void {
        const dir = try std.Io.Dir.cwd().openDir(ctx.io, ctx.args[0], .{});
        const old = dir.readFileAlloc(ctx.io, "snapshot.txt", ctx.gpa, .unlimited) catch "";
        var sql_out: std.ArrayList(u8) = .empty;
        var snapshot: std.ArrayList(u8) = .empty;
        var version: usize = 1;
        var lines = std.mem.splitScalar(u8, old, '\n');
        while (lines.next()) |l| {
            if (std.mem.startsWith(u8, l, "# version ")) version = 1 + try std.fmt.parseInt(usize, l[10..], 10);
        }
        try snapshot.print(ctx.gpa, "# version {d}\n", .{version});
        for (ctx.options) |maybe| {
            const t = maybe orelse continue;
            const table_line = try std.fmt.allocPrint(ctx.gpa, "table {s}\n", .{t.name});
            const new_table = std.mem.indexOf(u8, old, table_line) == null;
            try snapshot.appendSlice(ctx.gpa, table_line);
            if (new_table) try sql_out.print(ctx.gpa, "create table {s} ();\n", .{t.name});
            for (t.columns) |c| {
                const line = try std.fmt.allocPrint(ctx.gpa, "column {s}.{s} {s}{s}\n", .{ t.name, c.name, c.sql_type, if (c.nullable) "" else " not null" });
                try snapshot.appendSlice(ctx.gpa, line);
                if (std.mem.indexOf(u8, old, line) == null)
                    try sql_out.print(ctx.gpa, "alter table {s} add column {s} {s}{s};\n", .{ t.name, c.name, c.sql_type, if (c.nullable) "" else " not null" });
            }
        }
        if (sql_out.items.len == 0) return std.debug.print("postgres.migrate: nothing to do ({d} resources in the model)\n", .{ctx.model.resources.len});
        const file = try std.fmt.allocPrint(ctx.gpa, "{d:0>4}.sql", .{version});
        try dir.writeFile(ctx.io, .{ .sub_path = file, .data = sql_out.items });
        try dir.writeFile(ctx.io, .{ .sub_path = "snapshot.txt", .data = snapshot.items });
        std.debug.print("postgres.migrate: wrote {s}/{s}\n{s}", .{ ctx.args[0], file, sql_out.items });
    }
};
