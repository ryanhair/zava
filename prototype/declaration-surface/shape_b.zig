//! PROTOTYPE, throwaway. Shape B: annotated struct types.
//! The developer writes the record struct; a `resource` declaration on it carries
//! everything the fields cannot say. Names of fields are enum literals typed
//! against the struct's own fields.
const std = @import("std");
const core = @import("core.zig");

pub fn Field(comptime T: type) type {
    return std.meta.FieldEnum(T);
}

pub fn ActionOf(comptime T: type) type {
    return struct {
        name: []const u8,
        kind: core.ActionKind,
        accept: []const Field(T) = &.{},
    };
}

pub fn Options(comptime T: type) type {
    return struct {
        name: []const u8,
        table: []const u8,
        primary_key: Field(T),
        generated: []const Field(T) = &.{},
        relationships: []const core.Rel = &.{},
        actions: []const ActionOf(T) = &.{},
    };
}

pub fn belongsTo(comptime Self: type, comptime name: []const u8, comptime Dest: type, comptime key: Field(Self)) core.Rel {
    return .{ .name = name, .kind = .belongs_to, .destination_type = Dest, .key = @tagName(key) };
}

pub fn hasMany(comptime name: []const u8, comptime Dest: type, comptime key: Field(Dest)) core.Rel {
    return .{ .name = name, .kind = .has_many, .destination_type = Dest, .key = @tagName(key) };
}

pub fn Resource(comptime T: type) type {
    @setEvalBranchQuota(100_000);
    if (!@hasDecl(T, "resource"))
        @compileError("'" ++ @typeName(T) ++ "' is not a resource: it has no `pub const resource`");
    const o: Options(T) = T.resource;
    const info = @typeInfo(T).@"struct";

    var attrs: [info.field_names.len]core.Attr = undefined;
    for (info.field_names, info.field_types, 0..) |name, FT, i| {
        attrs[i] = .{ .name = name, .type = FT };
        if (std.mem.eql(u8, name, @tagName(o.primary_key))) attrs[i].primary_key = true;
        for (o.generated) |g| {
            if (std.mem.eql(u8, name, @tagName(g))) attrs[i].generated = true;
        }
    }
    var actions: [o.actions.len]core.Action = undefined;
    for (o.actions, 0..) |a, i| {
        var accept: [a.accept.len][]const u8 = undefined;
        for (a.accept, 0..) |f, j| accept[j] = @tagName(f);
        const frozen = accept;
        actions[i] = .{ .name = a.name, .kind = a.kind, .accept = &frozen };
    }
    const attrs_c = attrs;
    const actions_c = actions;
    const res: core.Res = .{
        .name = o.name,
        .table = o.table,
        .attributes = &attrs_c,
        .relationships = o.relationships,
        .actions = &actions_c,
    };
    core.validateRes(res);
    return struct {
        pub const Source = T;
        pub const model = res;
        pub const Record = T;
    };
}

/// Takes the annotated structs themselves.
pub fn Domain(comptime tuple: anytype) type {
    const n = tuple.len;
    var wrapped: [n]type = undefined;
    inline for (0..n) |i| wrapped[i] = Resource(tuple[i]);
    const w = wrapped;
    return core.Domain(w);
}
