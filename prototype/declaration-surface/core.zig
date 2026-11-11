//! PROTOTYPE, throwaway. Declaration surface (issue #6).
//! The normalized model every candidate declaration shape lowers to, plus the
//! derivations that read it. Not framework code.
const std = @import("std");

pub const Attr = struct {
    name: []const u8,
    type: type,
    primary_key: bool = false,
    generated: bool = false,
};

pub const RelKind = enum { belongs_to, has_many };

pub const Rel = struct {
    name: []const u8,
    kind: RelKind,
    /// Destination resource name.
    destination: []const u8 = "",
    /// Shapes that point at the destination by type leave the name for Domain() to resolve.
    destination_type: ?type = null,
    /// The foreign-key attribute: on this resource for belongs_to, on the destination for has_many.
    key: []const u8,
};

pub const ActionKind = enum { create, read, update };

pub const Action = struct {
    name: []const u8,
    kind: ActionKind,
    accept: []const []const u8 = &.{},
};

pub const Res = struct {
    name: []const u8,
    table: []const u8,
    attributes: []const Attr,
    relationships: []const Rel = &.{},
    actions: []const Action = &.{},
};

pub fn findAttr(comptime r: Res, comptime name: []const u8) ?Attr {
    for (r.attributes) |a| if (std.mem.eql(u8, a.name, name)) return a;
    return null;
}

/// Checks that need only the one resource.
pub fn validateRes(comptime r: Res) void {
    var pk: usize = 0;
    for (r.attributes, 0..) |a, i| {
        _ = sqlType(r, a);
        if (a.primary_key) pk += 1;
        for (r.attributes[0..i]) |prev| {
            if (std.mem.eql(u8, prev.name, a.name))
                @compileError("resource '" ++ r.name ++ "': duplicate attribute '" ++ a.name ++ "'");
        }
    }
    if (pk != 1) @compileError("resource '" ++ r.name ++ "': exactly one attribute must be the primary key");
    for (r.actions) |act| {
        for (act.accept) |name| {
            const a = findAttr(r, name) orelse
                @compileError("resource '" ++ r.name ++ "', action '" ++ act.name ++
                    "': accepts unknown attribute '" ++ name ++ "'");
            if (a.generated)
                @compileError("resource '" ++ r.name ++ "', action '" ++ act.name ++
                    "': cannot accept generated attribute '" ++ name ++ "'");
        }
    }
    for (r.relationships) |rel| {
        if (rel.kind == .belongs_to and findAttr(r, rel.key) == null)
            @compileError("resource '" ++ r.name ++ "', relationship '" ++ rel.name ++
                "': no attribute '" ++ rel.key ++ "' to hold the key");
    }
}

/// Checks that need the whole model.
pub fn validateDomain(comptime models: []const Res) void {
    for (models, 0..) |m, i| {
        for (models[0..i]) |prev| {
            if (std.mem.eql(u8, prev.name, m.name))
                @compileError("duplicate resource '" ++ m.name ++ "'");
        }
        for (m.relationships) |rel| {
            const dest = findRes(models, rel.destination) orelse
                @compileError("resource '" ++ m.name ++ "', relationship '" ++ rel.name ++
                    "': unknown destination resource '" ++ rel.destination ++ "'");
            if (rel.kind == .has_many and findAttr(dest, rel.key) == null)
                @compileError("resource '" ++ m.name ++ "', relationship '" ++ rel.name ++
                    "': destination '" ++ dest.name ++ "' has no attribute '" ++ rel.key ++ "'");
        }
    }
}

pub fn findRes(comptime models: []const Res, comptime name: []const u8) ?Res {
    for (models) |m| if (std.mem.eql(u8, m.name, name)) return m;
    return null;
}

/// `tuple` is a tuple or array of resource types, each exposing `model: Res` and `Record: type`.
pub fn Domain(comptime tuple: anytype) type {
    @setEvalBranchQuota(100_000);
    const n = tuple.len;
    var ms: [n]Res = undefined;
    inline for (0..n) |i| ms[i] = tuple[i].model;
    inline for (0..n) |i| {
        var rels: [ms[i].relationships.len]Rel = undefined;
        for (ms[i].relationships, 0..) |rel, j| {
            rels[j] = rel;
            if (rel.destination_type) |DT| {
                rels[j].destination = inline for (0..n) |k| {
                    if (@hasDecl(tuple[k], "Source") and tuple[k].Source == DT) break ms[k].name;
                } else @compileError("resource '" ++ ms[i].name ++ "', relationship '" ++ rel.name ++
                    "': destination type '" ++ @typeName(DT) ++ "' is not a resource in this domain");
            }
        }
        const frozen = rels;
        ms[i].relationships = &frozen;
    }
    const final = ms;
    validateDomain(&final);
    return struct {
        pub const resources = tuple;
        pub const models: []const Res = &final;
    };
}

pub fn RecordOf(comptime r: Res) type {
    var names: [r.attributes.len][]const u8 = undefined;
    var types: [r.attributes.len]type = undefined;
    for (r.attributes, 0..) |a, i| {
        names[i] = a.name;
        types[i] = a.type;
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

pub fn sqlType(comptime r: Res, comptime a: Attr) []const u8 {
    const T, const nullable = switch (@typeInfo(a.type)) {
        .optional => |o| .{ o.child, true },
        else => .{ a.type, false },
    };
    const base = switch (T) {
        i64 => "bigint",
        i32 => "integer",
        bool => "boolean",
        []const u8 => "text",
        else => @compileError("resource '" ++ r.name ++ "', attribute '" ++ a.name ++
            "': no Postgres type for Zig type '" ++ @typeName(a.type) ++ "'"),
    };
    return if (nullable) base else base ++ " not null";
}

/// Derivation that needs the whole model: belongs_to keys become foreign keys.
pub fn createTableSql(comptime models: []const Res, comptime r: Res) []const u8 {
    var s: []const u8 = "create table " ++ r.table ++ " (";
    for (r.attributes, 0..) |a, i| {
        if (i != 0) s = s ++ ", ";
        s = s ++ a.name ++ " " ++ sqlType(r, a);
        if (a.generated) s = s ++ " generated always as identity";
        if (a.primary_key) s = s ++ " primary key";
        for (r.relationships) |rel| {
            if (rel.kind == .belongs_to and std.mem.eql(u8, rel.key, a.name))
                s = s ++ " references " ++ findRes(models, rel.destination).?.table;
        }
    }
    return s ++ ")";
}

/// A stand-in "extension": reads the model, derives a route per action.
pub fn route(comptime r: Res, comptime act: Action) []const u8 {
    var s: []const u8 = switch (act.kind) {
        .create => "POST  ",
        .read => "GET   ",
        .update => "PATCH ",
    };
    s = s ++ "/" ++ r.table ++ "/" ++ act.name ++ " {";
    for (act.accept, 0..) |name, i| s = s ++ (if (i == 0) "" else ", ") ++ name;
    return s ++ "}";
}

/// Print everything a derivation can see. Same output for every shape is the point.
pub fn describe(out: *std.Io.Writer, comptime D: type) !void {
    @setEvalBranchQuota(100_000);
    inline for (D.models, 0..) |m, i| {
        try out.print("  resource {s}  record type: {s}\n", .{ m.name, @typeName(D.resources[i].Record) });
        inline for (m.relationships) |rel|
            try out.print("    {s} {s} -> {s} (key {s})\n", .{ @tagName(rel.kind), rel.name, rel.destination, rel.key });
        try out.print("    {s}\n", .{comptime createTableSql(D.models, m)});
        inline for (m.actions) |act| try out.print("    {s}\n", .{comptime route(m, act)});
    }
}
