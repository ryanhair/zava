const std = @import("std");

const postgres = struct {
    pub const name = "postgres";
    pub fn Options(comptime R: type) type {
        _ = R;
        return struct { table: []const u8, schema: []const u8 = "public" };
    }
};
const clash = struct {
    pub const name = "actions";
    pub fn Options(comptime R: type) type {
        _ = R;
        return struct { x: u8 = 0 };
    }
};
const extensions = if (mistake == 4) .{ postgres, clash } else .{postgres};
const mistake: u8 = @import("cfg").mistake;

pub fn Action(comptime R: type) type {
    return struct { name: []const u8, accept: []const std.meta.FieldEnum(R) = &.{} };
}

fn Kernel(comptime R: type) type {
    return struct {
        primary_key: std.meta.FieldEnum(R),
        actions: []const Action(R) = &.{},
    };
}

pub fn Options(comptime R: type) type {
    const K = Kernel(R);
    const info = @typeInfo(K).@"struct";
    const n = info.field_names.len + extensions.len;
    var names: [n][:0]const u8 = undefined;
    var types: [n]type = undefined;
    var attrs: [n]std.lang.Type.Struct.FieldAttributes = undefined;
    for (0..info.field_names.len) |i| {
        names[i] = info.field_names[i];
        types[i] = info.field_types[i];
        attrs[i] = info.field_attrs[i];
    }
    inline for (extensions, info.field_names.len..) |E, i| {
        for (info.field_names) |k| if (std.mem.eql(u8, k, E.name))
            @compileError("extension '" ++ E.name ++ "' has the name of a kernel option; an extension may not be named after a kernel option");
        const T = ?E.Options(R);
        const default: T = null;
        names[i] = E.name;
        types[i] = T;
        attrs[i] = .{ .default_value_ptr = &default };
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

pub const Author = struct {
    id: i64,
    email: []const u8,

    pub const resource = switch (mistake) {
        0, 4 => Options(@This()){
            .primary_key = .id,
            .actions = &.{.{ .name = "register", .accept = &.{.email} }},
            .postgres = .{ .table = "authors" },
        },
        1 => Options(@This()){ .primry_key = .id, .postgres = .{ .table = "authors" } },
        2 => Options(@This()){ .primary_key = .id, .postgre = .{ .table = "authors" } },
        3 => Options(@This()){ .primary_key = .id, .actions = &.{.{ .name = "r", .accept = &.{.emial} }}, .postgres = .{ .tabel = "a" } },
        5 => Options(@This()){ .postgres = .{ .table = "authors" } },
        else => unreachable,
    };
};

pub fn main() void {
    std.debug.print("{s} {s}\n", .{ @tagName(Author.resource.primary_key), Author.resource.postgres.?.table });
}
