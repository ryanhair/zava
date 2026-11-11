//! Further cheap things ZLS's builtin handling suggests might help a declaration.
const std = @import("std");

pub const Author = struct {
    id: i64,
    email: []const u8,
    name: []const u8,

    pub fn welcome(self: *Author) void {
        self.name = "Welcome";
    }
};

// E1: does ZLS offer field names inside the string argument of @FieldType / @field / @hasField?
const E1a = @FieldType(Author, "email");
const e1b: E1a = "x";
fn e1c(a: Author) []const u8 {
    return @field(a, "name");
}
const e1d = @hasField(Author, "email");

// E2: a value typed with @FieldType on a concrete struct (the type of one attribute).
fn Default(comptime T: type, comptime name: []const u8) type {
    return struct { value: @FieldType(T, name) };
}
const e2: Default(Author, "id") = .{ .value = 1 };
const e2_direct: struct { value: @FieldType(Author, "id") } = .{ .value = 1 };

// E3: the hook named by function value instead of by declaration name.
// (ADR 0003 rules this out for the build; measured only to show what completes.)
const Hooked = struct { after: ?*const fn (*Author) void = null };
const e3: Hooked = .{ .after = Author.welcome };

// E4: decl literal. A source-written wrapper with one declaration per attribute.
const AuthorField = struct {
    name: []const u8,
    pub const id: AuthorField = .{ .name = "id" };
    pub const email: AuthorField = .{ .name = "email" };
};
const e4: AuthorField = .email;

// E5: a union(enum) written by the developer; std.meta.FieldEnum of it is its tag type.
const AuthorAttr = union(enum) { id: i64, email: []const u8, name: []const u8 };
const e5: std.meta.FieldEnum(AuthorAttr) = .email;
const e5_tag: std.meta.Tag(AuthorAttr) = .email;
const e5_value: AuthorAttr = .{ .email = "x" };

test {
    _ = e1b;
    _ = e1c(.{ .id = 1, .email = "", .name = "" });
    _ = e1d;
    _ = e2;
    _ = e2_direct;
    _ = e3;
    _ = e4;
    _ = e5;
    _ = e5_tag;
    _ = e5_value;
}
