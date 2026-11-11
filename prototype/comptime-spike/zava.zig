//! PROTOTYPE, throwaway. Comptime thesis spike (issue #5).
//! One resource declared as comptime data; from it derive a record type,
//! SQL statements, and a JSON handler. Not framework code.
const std = @import("std");

pub const Attribute = struct {
    name: []const u8,
    type: type,
    primary_key: bool = false,
    /// Filled in by the data layer, never accepted as input.
    generated: bool = false,
};

pub const ActionKind = enum { create, read };

pub const Action = struct {
    name: []const u8,
    kind: ActionKind,
    /// Attribute names this action accepts as input.
    accept: []const []const u8 = &.{},
};

pub const Spec = struct {
    name: []const u8,
    table: []const u8,
    attributes: []const Attribute,
    actions: []const Action,
};

pub fn Resource(comptime spec: Spec) type {
    @setEvalBranchQuota(100_000);
    comptime validate(spec);
    return struct {
        pub const model = spec;
        /// Derivation 1: the record type.
        pub const Record = RecordOf(spec);
        /// Action names as an enum, so a typo is an ordinary type error.
        pub const ActionName = ActionEnum(spec);
        /// Derivation 2: SQL.
        pub const create_table_sql: []const u8 = createTableSql(spec);

        pub fn Input(comptime action: ActionName) type {
            // Spike finding: the quota raised in Resource() does not reach here.
            // Every comptime entry point starts again at 1000.
            @setEvalBranchQuota(100_000);
            return InputOf(spec, actionByName(spec, @tagName(action)));
        }

        pub fn sql(comptime action: ActionName) []const u8 {
            @setEvalBranchQuota(100_000);
            return comptime actionSql(spec, actionByName(spec, @tagName(action)));
        }

        /// Derivation 3: a JSON handler. Body in, JSON out. The "data layer"
        /// is a stub that echoes the statement and invents the generated columns.
        pub fn handle(
            comptime action: ActionName,
            arena: std.mem.Allocator,
            body: []const u8,
            out: *std.Io.Writer,
        ) !void {
            const act = comptime actionByName(spec, @tagName(action));
            const In = Input(action);
            const input = std.json.parseFromSliceLeaky(In, arena, body, .{}) catch |err| {
                try out.print("{{\"error\":\"invalid input for {s}.{s}: {s}\"}}\n", .{ spec.name, act.name, @errorName(err) });
                return;
            };
            var record: Record = undefined;
            inline for (spec.attributes) |attr| {
                if (@hasField(In, attr.name)) {
                    @field(record, attr.name) = @field(input, attr.name);
                } else if (attr.generated) {
                    @field(record, attr.name) = stubGenerated(attr.type);
                } else {
                    @field(record, attr.name) = stubGenerated(attr.type);
                }
            }
            try out.print("-- {s}\n", .{comptime sql(action)});
            try std.json.Stringify.value(record, .{}, out);
            try out.writeAll("\n");
        }
    };
}

fn stubGenerated(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .int => 1,
        .bool => false,
        .optional => null,
        .pointer => "stub",
        else => @compileError("stub: unsupported type " ++ @typeName(T)),
    };
}

fn validate(comptime spec: Spec) void {
    var pk_count: usize = 0;
    for (spec.attributes, 0..) |attr, i| {
        _ = sqlType(spec, attr);
        if (attr.primary_key) pk_count += 1;
        for (spec.attributes[0..i]) |prev| {
            if (std.mem.eql(u8, prev.name, attr.name))
                @compileError("resource '" ++ spec.name ++ "': duplicate attribute '" ++ attr.name ++ "'");
        }
    }
    if (pk_count != 1)
        @compileError("resource '" ++ spec.name ++ "': exactly one attribute must be the primary key");
    for (spec.actions) |act| {
        for (act.accept) |name| {
            const attr = findAttr(spec, name) orelse
                @compileError("resource '" ++ spec.name ++ "', action '" ++ act.name ++
                    "': accepts unknown attribute '" ++ name ++ "'");
            if (attr.generated)
                @compileError("resource '" ++ spec.name ++ "', action '" ++ act.name ++
                    "': cannot accept generated attribute '" ++ name ++ "'");
        }
    }
}

fn findAttr(comptime spec: Spec, comptime name: []const u8) ?Attribute {
    for (spec.attributes) |attr| {
        if (std.mem.eql(u8, attr.name, name)) return attr;
    }
    return null;
}

fn actionByName(comptime spec: Spec, comptime name: []const u8) Action {
    for (spec.actions) |act| {
        if (std.mem.eql(u8, act.name, name)) return act;
    }
    unreachable;
}

fn RecordOf(comptime spec: Spec) type {
    var names: [spec.attributes.len][]const u8 = undefined;
    var types: [spec.attributes.len]type = undefined;
    for (spec.attributes, 0..) |attr, i| {
        names[i] = attr.name;
        types[i] = attr.type;
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

fn InputOf(comptime spec: Spec, comptime act: Action) type {
    var names: [act.accept.len][]const u8 = undefined;
    var types: [act.accept.len]type = undefined;
    for (act.accept, 0..) |name, i| {
        names[i] = name;
        types[i] = findAttr(spec, name).?.type;
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

fn ActionEnum(comptime spec: Spec) type {
    var names: [spec.actions.len][]const u8 = undefined;
    var values: [spec.actions.len]u8 = undefined;
    for (spec.actions, 0..) |act, i| {
        names[i] = act.name;
        values[i] = i;
    }
    return @Enum(u8, .exhaustive, &names, &values);
}

fn sqlType(comptime spec: Spec, comptime attr: Attribute) []const u8 {
    const T, const nullable = switch (@typeInfo(attr.type)) {
        .optional => |o| .{ o.child, true },
        else => .{ attr.type, false },
    };
    const base = switch (T) {
        i64 => "bigint",
        i32 => "integer",
        bool => "boolean",
        []const u8 => "text",
        else => @compileError("resource '" ++ spec.name ++ "', attribute '" ++ attr.name ++
            "': no Postgres type for Zig type '" ++ @typeName(attr.type) ++ "'"),
    };
    return if (nullable) base else base ++ " not null";
}

fn createTableSql(comptime spec: Spec) []const u8 {
    var s: []const u8 = "create table " ++ spec.table ++ " (";
    for (spec.attributes, 0..) |attr, i| {
        if (i != 0) s = s ++ ", ";
        s = s ++ attr.name ++ " " ++ sqlType(spec, attr);
        if (attr.generated) s = s ++ " generated always as identity";
        if (attr.primary_key) s = s ++ " primary key";
    }
    return s ++ ")";
}

fn columnList(comptime spec: Spec) []const u8 {
    var s: []const u8 = "";
    for (spec.attributes, 0..) |attr, i| {
        if (i != 0) s = s ++ ", ";
        s = s ++ attr.name;
    }
    return s;
}

fn actionSql(comptime spec: Spec, comptime act: Action) []const u8 {
    switch (act.kind) {
        .create => {
            var cols: []const u8 = "";
            var params: []const u8 = "";
            for (act.accept, 0..) |name, i| {
                if (i != 0) {
                    cols = cols ++ ", ";
                    params = params ++ ", ";
                }
                cols = cols ++ name;
                params = params ++ "$" ++ digits(i + 1);
            }
            return "insert into " ++ spec.table ++ " (" ++ cols ++ ") values (" ++ params ++
                ") returning " ++ columnList(spec);
        },
        .read => {
            var where: []const u8 = "";
            for (act.accept, 0..) |name, i| {
                where = where ++ (if (i == 0) " where " else " and ") ++ name ++ " = $" ++ digits(i + 1);
            }
            return "select " ++ columnList(spec) ++ " from " ++ spec.table ++ where;
        },
    }
}

fn digits(comptime n: usize) []const u8 {
    var buf: []const u8 = "";
    var x = n;
    while (true) {
        buf = [_]u8{'0' + @as(u8, @intCast(x % 10))} ++ buf;
        x /= 10;
        if (x == 0) break;
    }
    return buf;
}
