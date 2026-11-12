//! PROTOTYPE, throwaway. The kernel: declaration types, lowering, the extension contract,
//! the one emitter, and the command runner. It never names an extension.
const std = @import("std");
const domain = @import("domain"); // the one domain of the build (ADR 0002)

pub const resources = domain.resources;
pub const extensions = domain.extensions;

// ---------------------------------------------------------------- declaration

pub const ActionKind = enum { create, read, update, destroy, generic };

pub fn Action(comptime R: type) type {
    return struct { name: []const u8, kind: ActionKind, accept: []const std.meta.FieldEnum(R) = &.{} };
}

pub const AttributeOptions = struct { unique: bool = false };

/// A block with one optional `T` per attribute of `R`, keyed by field name.
/// Public: an extension uses it for its own per-attribute options.
pub fn PerAttribute(comptime R: type, comptime T: type) type {
    const names = @typeInfo(R).@"struct".field_names;
    var types: [names.len]type = undefined;
    var attrs: [names.len]std.lang.Type.Struct.FieldAttributes = undefined;
    const default: T = .{};
    for (0..names.len) |i| {
        types[i] = T;
        attrs[i] = .{ .default_value_ptr = &default };
    }
    return @Struct(.auto, null, names, &types, &attrs);
}

/// One optional entry per registered extension, keyed by the extension's name.
fn ExtensionBlock(comptime R: type) type {
    var names: [extensions.len][:0]const u8 = undefined;
    var types: [extensions.len]type = undefined;
    var attrs: [extensions.len]std.lang.Type.Struct.FieldAttributes = undefined;
    inline for (extensions, 0..) |E, i| {
        const T = ?E.Options(R);
        const default: T = null;
        names[i] = E.name;
        types[i] = T;
        attrs[i] = .{ .default_value_ptr = &default };
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

pub fn Options(comptime R: type) type {
    return struct {
        name: []const u8,
        primary_key: std.meta.FieldEnum(R),
        attributes: PerAttribute(R, AttributeOptions) = .{},
        actions: []const Action(R) = &.{},
        extensions: ExtensionBlock(R) = .{},
    };
}

// ---------------------------------------------------------------- the model
// Plain data: no `type` anywhere, so the same value is the comptime and the runtime form.

pub const Attribute = struct { name: []const u8, zig_type: []const u8, optional: bool, unique: bool };
pub const ActionModel = struct { name: []const u8, kind: ActionKind, accept: []const []const u8 };
pub const Resource = struct {
    name: []const u8,
    type_name: []const u8,
    primary_key: []const u8,
    attributes: []const Attribute,
    actions: []const ActionModel,
};
pub const Model = struct { resources: []const Resource };

pub fn resource(comptime R: type) Resource {
    comptime {
        const decl: Options(R) = R.resource;
        const names = @typeInfo(R).@"struct".field_names;
        var attributes: [names.len]Attribute = undefined;
        for (names, 0..) |n, i| {
            const T = @FieldType(R, n);
            attributes[i] = .{
                .name = n,
                .zig_type = @typeName(T),
                .optional = @typeInfo(T) == .optional,
                .unique = @field(decl.attributes, n).unique,
            };
        }
        var actions: [decl.actions.len]ActionModel = undefined;
        for (decl.actions, 0..) |a, i| {
            var accept: [a.accept.len][]const u8 = undefined;
            for (a.accept, 0..) |f, j| accept[j] = @tagName(f);
            const acc = accept;
            actions[i] = .{ .name = a.name, .kind = a.kind, .accept = &acc };
        }
        const full = @typeName(R);
        const at = attributes;
        const ac = actions;
        return .{
            .name = decl.name,
            .type_name = full[std.mem.lastIndexOfScalar(u8, full, '.').? + 1 ..],
            .primary_key = @tagName(decl.primary_key),
            .attributes = &at,
            .actions = &ac,
        };
    }
}

pub const model: Model = blk: {
    var rs: [resources.len]Resource = undefined;
    for (resources, 0..) |R, i| rs[i] = resource(R);
    const r = rs;
    break :blk .{ .resources = &r };
};

// ---------------------------------------------------------------- extension contract
// An extension is a namespace (a file) with:
//   pub const name                                   key in the declaration, import name in generated source
//   pub fn Options(comptime R: type) type            what the developer writes
//   pub const Lowered                                plain data it normalizes its options to
//   pub fn lower(R, zava.Resource, ?Options(R)) Lowered    validation lives here
//   pub fn describe(R) []const zava.Description(E)   optional: developer-facing types and functions
//   pub fn actionDoc(R, action) ?[]const u8          optional: a derived value for the action's doc comment
//   pub const commands = struct { pub fn x(zava.Command(E)) !void }   optional: build-run code

/// An extension's normalized options for one resource. Comptime; other extensions may call it too.
pub fn options(comptime E: type, comptime R: type) E.Lowered {
    comptime return E.lower(R, resource(R), @field(@as(Options(R), R.resource).extensions, E.name));
}

/// The same for every resource, in model order. Usable at runtime.
pub fn allOptions(comptime E: type) []const E.Lowered {
    const all = comptime blk: {
        var a: [resources.len]E.Lowered = undefined;
        for (resources, 0..) |R, i| a[i] = options(E, R);
        const done = a;
        break :blk &done;
    };
    return all;
}

/// Reference to a type inside a description.
pub const TypeRef = union(enum) {
    /// Any type that already exists: a primitive, an attribute's type, a record,
    /// or a public declaration of the extension. The emitter finds its spelling.
    type: type,
    /// A type described by the same extension for the same resource.
    described: []const u8,
    optional: *const TypeRef,
    slice: *const TypeRef,
};
pub const Field = struct { name: [:0]const u8, type: TypeRef };

pub fn Description(comptime E: type) type {
    return union(enum) {
        @"struct": struct { name: []const u8, doc: []const u8 = "", fields: []const Field },
        @"enum": struct { name: []const u8, doc: []const u8 = "", tags: []const []const u8 },
        function: struct {
            name: []const u8,
            doc: []const u8 = "",
            params: []const Field = &.{},
            returns: TypeRef,
            /// The comptime function in the extension that does the work, by declaration name.
            /// Called as `delegate(R, params...)`.
            delegate: std.meta.DeclEnum(E),
        },
    };
}

/// Build-run code receives this. Everything in it is runtime data.
pub fn Command(comptime E: type) type {
    return struct {
        io: std.Io,
        gpa: std.mem.Allocator,
        model: *const Model,
        options: []const E.Lowered,
        args: []const [:0]const u8,
    };
}

// ---------------------------------------------------------------- comptime behaviour

/// Look a generated type up by name. Only evaluated where generated source exists.
pub fn Generated(comptime R: type, comptime name: []const u8) type {
    return @field(@field(@import("api"), resource(R).type_name), name);
}

fn pascal(comptime s: []const u8) []const u8 {
    var out: []const u8 = "";
    var up = true;
    for (s) |c| {
        if (c == '_') {
            up = true;
        } else {
            out = out ++ &[_]u8{if (up) std.ascii.toUpper(c) else c};
            up = false;
        }
    }
    return out;
}
pub fn inputName(comptime action: []const u8) []const u8 {
    return pascal(action) ++ "Input";
}

/// Stand-in for running an action: copies the input onto an empty record.
pub fn run(comptime R: type, comptime action: []const u8, input: Generated(R, inputName(action))) R {
    var r = std.mem.zeroes(R);
    inline for (@typeInfo(@TypeOf(input)).@"struct".field_names) |f| @field(r, f) = @field(input, f);
    return r;
}

// ---------------------------------------------------------------- the emitter

fn isExtensionDecl(comptime T: type) ?[]const u8 {
    for (extensions) |E| {
        for (@typeInfo(E).@"struct".decl_names) |d| {
            // Only constants that hold a type can match; skip functions without resolving them.
            if (@typeInfo(@TypeOf(@field(E, d))) != .type) continue;
            if (@field(E, d) == T) return E.name ++ "." ++ d;
        }
    }
    return null;
}

/// The source spelling of an existing type, or a compile error naming the description.
fn spell(comptime T: type, comptime where: []const u8) []const u8 {
    comptime {
        switch (@typeInfo(T)) {
            .int, .float, .bool, .void => return @typeName(T),
            .optional => |o| return "?" ++ spell(o.child, where),
            .pointer => |p| if (p.size == .slice and p.attrs.@"const") return "[]const " ++ spell(p.child, where),
            .@"struct", .@"enum", .@"union" => {
                for (resources) |R| if (R == T) return "domain." ++ resource(R).type_name;
                if (isExtensionDecl(T)) |s| return s;
            },
            else => {},
        }
        @compileError(where ++ ": type '" ++ @typeName(T) ++ "' has no spelling in generated source; " ++
            "use a primitive, a record, or a public declaration of the extension");
    }
}

fn spellRef(comptime ref: TypeRef, comptime where: []const u8) []const u8 {
    comptime return switch (ref) {
        .type => |T| spell(T, where),
        .described => |n| n,
        .optional => |r| "?" ++ spellRef(r.*, where),
        .slice => |r| "[]const " ++ spellRef(r.*, where),
    };
}

fn descriptionName(comptime d: anytype) []const u8 {
    return switch (d) {
        inline else => |x| x.name,
    };
}

/// Two extensions (or an extension and the kernel) may not describe the same name on one resource.
fn checkCollisions(comptime R: type) void {
    comptime {
        const res = resource(R);
        var names: []const []const u8 = &.{};
        var owners: []const []const u8 = &.{};
        for (res.actions) |a| {
            names = names ++ .{ a.name, inputName(a.name) };
            owners = owners ++ .{ "the kernel", "the kernel" };
        }
        for (extensions) |E| {
            if (!@hasDecl(E, "describe")) continue;
            for (E.describe(R)) |d| {
                const n = descriptionName(d);
                for (names, owners) |m, o| if (std.mem.eql(u8, m, n))
                    @compileError("extension '" ++ E.name ++ "' describes '" ++ res.type_name ++ "." ++ n ++ "', already described by " ++ o);
                names = names ++ .{n};
                owners = owners ++ .{"extension '" ++ E.name ++ "'"};
            }
        }
    }
}

pub fn emit(w: *std.Io.Writer) !void {
    try w.writeAll("//! GENERATED by the zava kernel. Do not edit.\nconst zava = @import(\"zava\");\nconst domain = @import(\"domain\");\n");
    inline for (extensions) |E| try w.print("const {s} = @import(\"{s}\");\n", .{ E.name, E.name });
    inline for (resources) |R| {
        comptime checkCollisions(R);
        const res = comptime resource(R);
        try w.print("\npub const {s} = struct {{\n", .{res.type_name});
        inline for (res.actions) |a| {
            try w.print("    pub const {s} = struct {{\n", .{comptime inputName(a.name)});
            inline for (a.accept) |f| try w.print("        {s}: {s},\n", .{ f, comptime spell(@FieldType(R, f), "input") });
            try w.print("    }};\n\n    /// Runs the `{s}` action on `{s}`.\n", .{ a.name, res.name });
            inline for (extensions) |E| if (@hasDecl(E, "actionDoc")) {
                if (comptime E.actionDoc(R, a.name)) |doc| try w.print("    /// {s}: {s}\n", .{ E.name, doc });
            };
            try w.print("    pub fn {s}(input: {s}) domain.{s} {{\n        return zava.run(domain.{s}, \"{s}\", input);\n    }}\n\n", .{ a.name, comptime inputName(a.name), res.type_name, res.type_name, a.name });
        }
        inline for (extensions) |E| if (@hasDecl(E, "describe")) {
            const ds = comptime E.describe(R);
            if (ds.len > 0) try w.print("    // ---- described by the `{s}` extension\n\n", .{E.name});
            inline for (ds) |d| {
                const where = comptime "extension '" ++ E.name ++ "', description '" ++ res.type_name ++ "." ++ descriptionName(d) ++ "'";
                switch (d) {
                    .@"struct" => |s| {
                        if (s.doc.len > 0) try w.print("    /// {s}\n", .{s.doc});
                        try w.print("    pub const {s} = struct {{\n", .{s.name});
                        inline for (s.fields) |f| try w.print("        {s}: {s},\n", .{ f.name, comptime spellRef(f.type, where) });
                        try w.writeAll("    };\n\n");
                    },
                    .@"enum" => |e| {
                        if (e.doc.len > 0) try w.print("    /// {s}\n", .{e.doc});
                        try w.print("    pub const {s} = enum {{", .{e.name});
                        inline for (e.tags) |t| try w.print(" {s},", .{t});
                        try w.writeAll(" };\n\n");
                    },
                    .function => |f| {
                        if (f.doc.len > 0) try w.print("    /// {s}\n", .{f.doc});
                        try w.print("    pub fn {s}(", .{f.name});
                        inline for (f.params, 0..) |p, i| try w.print("{s}{s}: {s}", .{ if (i > 0) ", " else "", p.name, comptime spellRef(p.type, where) });
                        try w.print(") {s} {{\n        return {s}.{s}(domain.{s}", .{ comptime spellRef(f.returns, where), E.name, @tagName(f.delegate), res.type_name });
                        inline for (f.params) |p| try w.print(", {s}", .{p.name});
                        try w.writeAll(");\n    }\n\n");
                    },
                }
            }
        };
        try w.writeAll("};\n");
    }
}

// ---------------------------------------------------------------- the command runner

/// `runner <extension>.<command> args...`; with no arguments, lists the commands.
pub fn runCommand(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    inline for (extensions) |E| if (@hasDecl(E, "commands")) {
        inline for (@typeInfo(E.commands).@"struct".decl_names) |c| {
            const full = E.name ++ "." ++ c;
            if (args.len < 2) {
                std.debug.print("{s}\n", .{full});
            } else if (std.mem.eql(u8, args[1], full)) {
                const all = allOptions(E);
                return @field(E.commands, c)(Command(E){ .io = init.io, .gpa = init.arena.allocator(), .model = &model, .options = all, .args = args[2..] });
            }
        }
    };
    if (args.len >= 2) return error.UnknownCommand;
}
