//! PROTOTYPE probe: what controls the name of a derived type, and can a derived type be handed methods or error sets?
const std = @import("std");

const Attr = struct { name: []const u8, type: type };

fn build(comptime attrs: []const Attr) type {
    var names: [attrs.len][]const u8 = undefined;
    var types: [attrs.len]type = undefined;
    for (attrs, 0..) |a, i| {
        names[i] = a.name;
        types[i] = a.type;
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

// A: spec passed as a value.
fn ByValue(comptime attrs: []const Attr) type {
    return build(attrs);
}
// B: spec passed as a user-named type holding the data.
fn ByType(comptime S: type) type {
    return build(S.attributes);
}
// C: short string key plus the data.
fn ByKey(comptime name: []const u8, comptime attrs: []const Attr) type {
    _ = name;
    return build(attrs);
}
// D: user writes the struct; framework reflects on it.
const UserD = struct {
    id: i64,
    email: []const u8,
    pub const table = "users";
};
// E: wrapper struct returned from a function taking a named spec type.
fn Wrapper(comptime S: type) type {
    return struct {
        pub const Record = build(S.attributes);
        row: Record,
        pub fn save(self: @This()) void {
            _ = self;
        }
    };
}

const user_attrs: []const Attr = &.{ .{ .name = "id", .type = i64 }, .{ .name = "email", .type = []const u8 } };
const UserSpec = struct {
    pub const attributes = user_attrs;
};

pub fn main() void {
    std.debug.print("A by value      : {s}\n", .{@typeName(ByValue(user_attrs))});
    std.debug.print("B by named type : {s}\n", .{@typeName(ByType(UserSpec))});
    std.debug.print("C by string key : {s}\n", .{@typeName(ByKey("user", user_attrs))});
    std.debug.print("D user struct   : {s}\n", .{@typeName(UserD)});
    std.debug.print("E wrapper       : {s}\n", .{@typeName(Wrapper(UserSpec))});
    std.debug.print("E wrapper.Record: {s}\n", .{@typeName(Wrapper(UserSpec).Record)});
    std.debug.print("F keyed by type : {s}\n", .{@typeName(RecordOf(UserSpec))});
    std.debug.print("same type A==B? : {}\n", .{ByValue(user_attrs) == ByType(UserSpec)});
    std.debug.print("A==A again?     : {}\n", .{ByValue(user_attrs) == ByValue(&.{ .{ .name = "id", .type = i64 }, .{ .name = "email", .type = []const u8 } })});
}

// F: @Struct called directly in a function keyed by the user's named spec type.
fn RecordOf(comptime S: type) type {
    var names: [S.attributes.len][]const u8 = undefined;
    var types: [S.attributes.len]type = undefined;
    for (S.attributes, 0..) |a, i| {
        names[i] = a.name;
        types[i] = a.type;
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}
