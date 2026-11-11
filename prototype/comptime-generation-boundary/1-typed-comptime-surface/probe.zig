const std = @import("std");

pub const Action = struct { name: [:0]const u8, accept: []const [:0]const u8 };

pub const Author = struct {
    id: i64,
    email: []const u8,
    name: []const u8,
    pub const actions: []const Action = &.{
        .{ .name = "register", .accept = &.{ "email", "name" } },
        .{ .name = "rename", .accept = &.{"name"} },
    };
};

pub fn ActionName(comptime R: type) type {
    var names: [R.actions.len][]const u8 = undefined;
    for (R.actions, 0..) |a, i| names[i] = a.name;
    return @Enum(u8, .exhaustive, &names, &std.simd.iota(u8, R.actions.len));
}

pub fn Input(comptime R: type, comptime action: ActionName(R)) type {
    const a = R.actions[@intFromEnum(action)];
    var names: [a.accept.len][]const u8 = undefined;
    var types: [a.accept.len]type = undefined;
    for (a.accept, 0..) |n, i| {
        names[i] = n;
        types[i] = @FieldType(R, n);
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

pub const Error = error{ Invalid, Forbidden, Conflict };

pub fn run(comptime R: type, comptime action: ActionName(R), input: Input(R, action)) Error!R {
    var r: R = undefined;
    inline for (@typeInfo(@TypeOf(input)).@"struct".field_names) |n| @field(r, n) = @field(input, n);
    return r;
}

// user-written, fully typed hook: no anytype
fn normalize(input: *Input(Author, .register)) void {
    input.name = "Ann";
}

pub fn main() !void {
    var in: Input(Author, .register) = .{ .email = "a@b.c", .name = "ann" };
    normalize(&in);
    const a = try run(Author, .register, in);
    std.debug.print("{s} {s}\n", .{ a.email, a.name });
    if (@hasDecl(@This(), "BAD1")) _ = try run(Author, .register, .{ .emial = "x", .name = "y" });
}
