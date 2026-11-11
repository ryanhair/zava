//! Extra cases that bound what ZLS can and cannot follow. Each block is a
//! different way of producing a type at comptime, from simplest to the probe's
//! pattern. Compiles and runs on Zig 0.17.0.
const std = @import("std");

pub const Author = struct {
    id: i64,
    email: []const u8,
    name: []const u8,

    // hand-written (or generated) pieces used by V4/V5
    pub const ActionName = enum { register, rename };
    pub const RegisterInput = struct { email: []const u8, name: []const u8 };
    pub const RenameInput = struct { name: []const u8 };
};

// V1: @Struct with literal arguments, no loop, no function.
pub const V1 = @Struct(.auto, null, &.{ "email", "name" }, &.{ []const u8, []const u8 }, &@splat(.{}));

// V2: @Enum with literal arguments.
pub const V2 = @Enum(u8, .exhaustive, &.{ "register", "rename" }, &.{ 0, 1 });

// V3: classic generic: a struct literal returned from a type function, with
// field types computed from the record.
pub fn V3(comptime R: type) type {
    return struct {
        email: @FieldType(R, "email"),
        record: R,
    };
}

// V4: a type function that only selects among declared types.
pub fn V4Name(comptime R: type) type {
    return R.ActionName;
}
pub fn v4(comptime R: type, action: V4Name(R)) void {
    _ = action;
}

// V5: a type function that switches on a comptime enum value to pick a declared struct.
pub fn V5(comptime R: type, comptime action: R.ActionName) type {
    return switch (action) {
        .register => R.RegisterInput,
        .rename => R.RenameInput,
    };
}
pub fn v5(comptime R: type, comptime action: R.ActionName, input: V5(R, action)) void {
    _ = input;
}

// V6: one declared function per action, input type looked up by name.
pub fn V6(comptime R: type) type {
    return struct {
        pub fn register(input: R.RegisterInput) R {
            return .{ .id = 1, .email = input.email, .name = input.name };
        }
    };
}

// V8: the V3 generic struct used as a concrete parameter type.
pub fn v8(input: V3(Author)) void {
    _ = input;
}

// V7: std.meta.FieldEnum, the standard library's own derived enum.
pub const V7 = std.meta.FieldEnum(Author);

pub fn main() void {
    const v1: V1 = .{ .email = "e", .name = "n" };
    _ = v1.email;
    const v2: V2 = .register;
    _ = v2;
    const v3: V3(Author) = .{ .email = "e", .record = undefined };
    _ = v3.email;
    v4(Author, .register);
    const v4b: V4Name(Author) = .register;
    _ = v4b;
    const v5_in: V5(Author, .register) = .{ .email = "e", .name = "n" };
    _ = v5_in.email;
    v5(Author, .register, .{ .email = "e", .name = "n" });
    const v6 = V6(Author).register(.{ .email = "e", .name = "n" });
    _ = v6.email;
    const AuthorV6 = V6(Author);
    const v6b = AuthorV6.register(.{ .email = "e", .name = "n" });
    _ = v6b;
    v8(.{ .email = "e", .record = undefined });
    const v7: V7 = .email;
    _ = v7;
}
