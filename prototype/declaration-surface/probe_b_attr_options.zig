//! PROTOTYPE probe. Shape B's weak spot: per-attribute metadata lives away from the field.
//! Can it at least be typed, so a wrong field name or option is a compiler-native error?
const std = @import("std");

pub const AttrOptions = struct { unique: bool = false, column: ?[]const u8 = null };

/// One optional AttrOptions per field of T.
pub fn AttrsOf(comptime T: type) type {
    const names = @typeInfo(T).@"struct".field_names;
    var types: [names.len]type = undefined;
    var attrs: [names.len]std.lang.Type.Struct.FieldAttributes = undefined;
    const default: AttrOptions = .{};
    for (0..names.len) |i| {
        types[i] = AttrOptions;
        attrs[i] = .{ .default_value_ptr = &default };
    }
    return @Struct(.auto, null, names, &types, &attrs);
}

pub const Author = struct {
    id: i64,
    email: []const u8,
    name: []const u8,

    pub const attributes: AttrsOf(@This()) = .{
        .email = .{ .unique = true, .column = "email_address" },
        // BAD .emial = .{ .unique = true },
    };
};

pub fn main() void {
    std.debug.print("email unique: {}, column {?s}; name unique: {}\n", .{
        Author.attributes.email.unique, Author.attributes.email.column, Author.attributes.name.unique,
    });
}
