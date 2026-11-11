//! Declaration-side types for question 2: what ZLS offers while a developer
//! writes `pub const resource: ... = .{ ... }`. Four ways of typing the same declaration.
const std = @import("std");

pub const ActionKind = enum { create, read, update };

/// Options for one attribute.
pub const AttrOptions = struct {
    /// Enforce uniqueness in the data layer.
    unique: bool = false,
    /// Column name, when it differs from the field name.
    column: ?[]const u8 = null,
};

// ---------------------------------------------------------------- variant A (ADR 0001 as prototyped)

/// One optional AttrOptions per field of T (a comptime-built struct).
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

pub fn ActionOf(comptime T: type) type {
    return struct {
        name: []const u8,
        kind: ActionKind = .update,
        /// Attributes the caller may set.
        accept: []const std.meta.FieldEnum(T) = &.{},
        /// A function of the resource, by declaration name, run after the action.
        after: ?std.meta.DeclEnum(T) = null,
    };
}

/// Everything the fields cannot say. Attribute names are an enum derived from the struct's fields.
pub fn Options(comptime T: type) type {
    return struct {
        /// Table name in the data layer.
        table: []const u8,
        /// The attribute that identifies a record.
        primary_key: std.meta.FieldEnum(T),
        actions: []const ActionOf(T) = &.{},
        /// Per-attribute options, keyed by field name.
        attributes: AttrsOf(T) = .{},
    };
}

// ---------------------------------------------------------------- variant B (source enum found through T)

fn checkFields(comptime T: type, comptime F: type) void {
    const want = @typeInfo(T).@"struct".field_names;
    const have = @typeInfo(F).@"enum".field_names;
    if (want.len != have.len) @compileError(@typeName(F) ++ " does not list the fields of " ++ @typeName(T));
    for (want, have) |w, h| if (!std.mem.eql(u8, w, h)) @compileError(@typeName(F) ++ ": expected '" ++ w ++ "', found '" ++ h ++ "'");
}

/// Attribute names are `T.Field`, an enum the developer writes inside the struct.
pub fn OptionsDecl(comptime T: type) type {
    checkFields(T, T.Field);
    return struct {
        /// Table name in the data layer.
        table: []const u8,
        /// The attribute that identifies a record.
        primary_key: T.Field,
        actions: []const struct {
            name: []const u8,
            kind: ActionKind = .update,
            accept: []const T.Field = &.{},
            after: ?std.meta.DeclEnum(T) = null,
        } = &.{},
        /// Per-attribute options, keyed by field name.
        attributes: std.enums.EnumFieldStruct(T.Field, AttrOptions, .{}) = .{},
    };
}

// ---------------------------------------------------------------- variant C (source enum passed as a parameter)

pub fn ActionF(comptime T: type, comptime F: type) type {
    return struct {
        name: []const u8,
        kind: ActionKind = .update,
        /// Attributes the caller may set.
        accept: []const F = &.{},
        /// A function of the resource, by declaration name, run after the action.
        after: ?std.meta.DeclEnum(T) = null,
    };
}

/// Attribute names are `F`, an enum the developer writes and passes in. Keyed attributes block.
pub fn OptionsF(comptime T: type, comptime F: type) type {
    checkFields(T, F);
    return struct {
        /// Table name in the data layer.
        table: []const u8,
        /// The attribute that identifies a record.
        primary_key: F,
        actions: []const ActionF(T, F) = &.{},
        /// Per-attribute options, keyed by field name.
        attributes: std.enums.EnumFieldStruct(F, AttrOptions, .{}) = .{},
    };
}

// ---------------------------------------------------------------- variant D (as C, attributes as a list)

pub fn AttrEntry(comptime F: type) type {
    return struct {
        /// The attribute these options belong to.
        field: F,
        /// Enforce uniqueness in the data layer.
        unique: bool = false,
        /// Column name, when it differs from the field name.
        column: ?[]const u8 = null,
    };
}

/// As `OptionsF`, with every derived type removed: per-attribute options are a
/// list of entries naming their field, and hooks are an enum the developer writes.
pub fn OptionsList(comptime T: type, comptime F: type, comptime Hook: type) type {
    checkFields(T, F);
    for (@typeInfo(Hook).@"enum".field_names) |h| if (!@hasDecl(T, h)) @compileError(@typeName(T) ++ " has no declaration '" ++ h ++ "'");
    return struct {
        /// Table name in the data layer.
        table: []const u8,
        /// The attribute that identifies a record.
        primary_key: F,
        actions: []const ActionL(F, Hook) = &.{},
        /// Per-attribute options.
        attributes: []const AttrEntry(F) = &.{},
    };
}

pub fn ActionL(comptime F: type, comptime Hook: type) type {
    return struct {
        name: []const u8,
        kind: ActionKind = .update,
        /// Attributes the caller may set.
        accept: []const F = &.{},
        /// A function of the resource, by declaration name, run after the action.
        after: ?Hook = null,
    };
}

// ---------------------------------------------------------------- forms: the literal as a function argument

/// Variant A with the literal passed as an argument instead of annotated on the declaration.
pub fn resource(comptime T: type, comptime options: Options(T)) Options(T) {
    return options;
}

/// Variant D with the literal passed as an argument instead of annotated on the declaration.
pub fn resourceList(comptime T: type, comptime F: type, comptime Hook: type, comptime options: OptionsList(T, F, Hook)) OptionsList(T, F, Hook) {
    return options;
}
