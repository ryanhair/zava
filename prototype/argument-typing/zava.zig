//! PROTOTYPE, throwaway. Typing argument names in expressions.
//! Cut down from prototype/expression-language: one representation, one checker, no SQL.
const std = @import("std");

// ================================================================ the representation

pub const Kind = enum { boolean, integer, text };
pub const Value = union(enum) { boolean: bool, integer: i64, text: []const u8 };
pub const Op = enum { eq, gt, all };

pub const Node = union(enum) {
    ref: []const u8,
    /// `from` is the name of the arguments type the developer named at the argument
    /// (shape 2 only), so the checker can report a mismatch with the action's.
    arg: struct { name: []const u8, from: []const u8 = "" },
    value: Value,
    call: struct { op: Op, arity: u8 },
};
pub const Expr = []const Node;

// ================================================================ the model (plain data)

pub const Attribute = struct { name: []const u8, kind: Kind };
pub const Argument = struct { name: []const u8, kind: Kind, min: ?i64 = null };
pub const Action = struct { name: []const u8, arguments: []const Argument, arguments_type: []const u8, filter: ?Expr };
pub const Resource = struct { name: []const u8, attributes: []const Attribute, actions: []const Action };
pub const Model = struct { resources: []const Resource };

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ================================================================ typed surface

pub const capacity = 32;

pub const Any = struct {
    nodes: [capacity]Node = undefined,
    len: u8 = 0,

    fn push(a: *Any, n: Node) void {
        if (a.len == capacity) @panic("expression has more than 32 nodes");
        a.nodes[a.len] = n;
        a.len += 1;
    }
    fn of(head: Node, parts: []const Expr) Any {
        var a: Any = .{};
        a.push(head);
        for (parts) |p| for (p) |n| a.push(n);
        return a;
    }
    pub fn expr(a: *const Any) Expr {
        return a.nodes[0..a.len];
    }
};

pub fn Attr(comptime R: type) type {
    return std.meta.FieldEnum(R);
}
pub fn AttrType(comptime R: type, comptime a: Attr(R)) type {
    return @FieldType(R, @tagName(a));
}

pub fn kindOf(comptime T: type) Kind {
    if (T == []const u8) return .text;
    return switch (@typeInfo(T)) {
        .bool => .boolean,
        .int, .comptime_int => .integer,
        .@"enum" => .text,
        else => @compileError("type '" ++ @typeName(T) ++ "' cannot appear in an expression"),
    };
}
fn toValue(v: anytype) Value {
    const T = @TypeOf(v);
    if (T == []const u8) return .{ .text = v };
    return switch (@typeInfo(T)) {
        .bool => .{ .boolean = v },
        .int, .comptime_int => .{ .integer = v },
        .@"enum" => .{ .text = @tagName(v) },
        else => @compileError("type '" ++ @typeName(T) ++ "' cannot appear in an expression"),
    };
}

/// Marker: the term does not know the arguments of the action it is written in.
pub const Unknown = struct {};

/// The names `.arg(...)` accepts in a term over arguments `A` whose result is a `V`.
/// Arguments unknown: any name (checked when the model is lowered).
/// Arguments known: an enum of exactly the arguments of type `V`, so a misspelled name
/// and a name of the wrong type are both "no such member", on the token.
pub fn ArgName(comptime A: type, comptime V: type) type {
    if (A == Unknown) return @EnumLiteral();
    const all = std.meta.fieldNames(A);
    var names: [all.len][]const u8 = undefined;
    var n: usize = 0;
    for (all) |name| if (@FieldType(A, name) == V) {
        names[n] = name;
        n += 1;
    };
    if (n == 0) return enum {};
    const Tag = std.math.IntFittingRange(0, n - 1);
    const kept = names[0..n].*;
    return @Enum(Tag, .exhaustive, &kept, &std.simd.iota(Tag, n));
}

/// An expression over resource `R`, inside an action whose arguments are `A`, giving a `V`.
pub fn Term(comptime R: type, comptime A: type, comptime V: type) type {
    return struct {
        any: Any,
        const Self = @This();

        fn mustBe(comptime T: type, comptime what: []const u8) void {
            if (V != T) @compileError(what ++ " gives " ++ @typeName(T) ++ ", but " ++ @typeName(V) ++ " is expected here");
        }

        pub fn value(v: V) Self {
            return .{ .any = .of(.{ .value = toValue(v) }, &.{}) };
        }
        pub fn attr(comptime a: Attr(R)) Self {
            comptime mustBe(AttrType(R, a), "attribute '" ++ @tagName(a) ++ "'");
            return .{ .any = .of(.{ .ref = @tagName(a) }, &.{}) };
        }

        /// Shapes 0 and 1. In shape 0 `A` is `Unknown` and the name is any enum literal.
        pub fn arg(comptime name: ArgName(A, V)) Self {
            return .{ .any = .of(.{ .arg = .{ .name = @tagName(name) } }, &.{}) };
        }
        /// Shape 2: the arguments type is named at the argument, as a destination is
        /// named when a relationship is crossed (ADR 0006).
        pub fn argOf(comptime Args: type, comptime name: std.meta.FieldEnum(Args)) Self {
            comptime mustBe(@FieldType(Args, @tagName(name)), "argument '" ++ @tagName(name) ++ "'");
            return .{ .any = .of(.{ .arg = .{ .name = @tagName(name), .from = @typeName(Args) } }, &.{}) };
        }

        fn compare(comptime op: Op, comptime a: Attr(R), rhs: Term(R, A, AttrType(R, a))) Self {
            comptime mustBe(bool, "a comparison");
            return .{ .any = .of(.{ .call = .{ .op = op, .arity = 2 } }, &.{ &.{.{ .ref = @tagName(a) }}, rhs.any.expr() }) };
        }
        pub fn eq(comptime a: Attr(R), rhs: Term(R, A, AttrType(R, a))) Self {
            return compare(.eq, a, rhs);
        }
        pub fn gt(comptime a: Attr(R), rhs: Term(R, A, AttrType(R, a))) Self {
            return compare(.gt, a, rhs);
        }
        pub fn all(ts: []const Self) Self {
            comptime mustBe(bool, "'all'");
            var a: Any = .{};
            a.push(.{ .call = .{ .op = .all, .arity = @intCast(ts.len) } });
            for (ts) |t| for (t.any.expr()) |n| a.push(n);
            return .{ .any = a };
        }
    };
}

// ================================================================ the declaration

/// Shape 0: an argument is an entry in a list.
pub const ArgumentEntry = struct { name: []const u8, type: type, min: ?i64 = null };

/// Shapes 1 and 2: options an argument adds to its type, in a block keyed by argument
/// name, as a resource's per-attribute options are keyed by field name.
pub const ArgumentOptions = struct { min: ?i64 = null };
pub fn ArgumentsBlock(comptime Args: type) type {
    const names = std.meta.fieldNames(Args);
    return @Struct(.auto, null, names, &@splat(ArgumentOptions), &@splat(.{ .default_value_ptr = &ArgumentOptions{} }));
}

/// Shape 1: everything in an action entry that may read the action's arguments.
pub fn ReadBody(comptime R: type, comptime Args: type) type {
    return struct {
        arguments: ArgumentsBlock(Args) = .{},
        filter: ?Term(R, Args, bool) = null,
    };
}

pub fn ActionEntry(comptime R: type) type {
    return struct {
        name: []const u8,
        /// Shape 0.
        arguments: []const ArgumentEntry = &.{},
        /// Shape 2: the arguments as a struct type the developer wrote and named.
        args: ?type = null,
        args_options: []const ?i64 = &.{}, // filled by `read` only
        filter: ?Term(R, Unknown, bool) = null,

        /// Shape 1: the arguments are a struct type, a parameter, so the body is typed on them.
        pub fn read(comptime name: []const u8, comptime Args: type, body: ReadBody(R, Args)) @This() {
            const names = std.meta.fieldNames(Args);
            var mins: [names.len]?i64 = undefined;
            for (names, 0..) |n, i| mins[i] = @field(body.arguments, n).min;
            const m = mins;
            return .{
                .name = name,
                .args = Args,
                .args_options = &m,
                .filter = if (body.filter) |f| .{ .any = f.any } else null,
            };
        }
    };
}
pub fn Options(comptime R: type) type {
    return struct {
        name: []const u8,
        actions: []const ActionEntry(R) = &.{},
    };
}

// ================================================================ lowering the declaration

fn fixed(comptime a: Any) Expr {
    const n = a.nodes[0..a.len].*;
    return &n;
}

fn lowerResource(comptime R: type) Resource {
    comptime {
        const decl: Options(R) = R.resource;
        const names = std.meta.fieldNames(R);
        var attributes: [names.len]Attribute = undefined;
        for (names, 0..) |n, i| attributes[i] = .{ .name = n, .kind = kindOf(@FieldType(R, n)) };
        var actions: [decl.actions.len]Action = undefined;
        for (decl.actions, 0..) |a, i| {
            var arguments: []const Argument = &.{};
            var arguments_type: []const u8 = "";
            if (a.args) |Args| {
                arguments_type = @typeName(Args);
                for (std.meta.fieldNames(Args), 0..) |n, j| arguments = arguments ++ &[_]Argument{.{
                    .name = n,
                    .kind = kindOf(@FieldType(Args, n)),
                    .min = if (j < a.args_options.len) a.args_options[j] else null,
                }};
            } else for (a.arguments) |g| {
                arguments = arguments ++ &[_]Argument{.{ .name = g.name, .kind = kindOf(g.type), .min = g.min }};
            }
            actions[i] = .{ .name = a.name, .arguments = arguments, .arguments_type = arguments_type, .filter = if (a.filter) |f| fixed(f.any) else null };
        }
        const at = attributes;
        const ac = actions;
        return .{ .name = decl.name, .attributes = &at, .actions = &ac };
    }
}

/// Lowers every declaration, then checks every expression in the model.
pub fn model(comptime resources: anytype) Model {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var rs: [resources.len]Resource = undefined;
        for (resources, 0..) |R, i| rs[i] = lowerResource(R);
        const done = rs;
        const m: Model = .{ .resources = &done };
        for (m.resources) |*r| for (r.actions) |*a| if (a.filter) |f| {
            const where = r.name ++ ", action '" ++ a.name ++ "', filter";
            var d: Diag = .{};
            const got = check(r, a, f, &d) catch @compileError(where ++ ": " ++ d.message());
            if (got != .boolean) @compileError(where ++ ": the expression is " ++ @tagName(got) ++ ", expected boolean");
        };
        return m;
    }
}

// ================================================================ the checker

pub const Diag = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,
    fn fail(d: *Diag, parts: []const []const u8) error{Invalid} {
        d.len = 0;
        for (parts) |p| {
            const n = @min(p.len, d.buf.len - d.len);
            @memcpy(d.buf[d.len..][0..n], p[0..n]);
            d.len += n;
        }
        return error.Invalid;
    }
    pub fn message(d: *const Diag) []const u8 {
        return d.buf[0..d.len];
    }
};

pub fn check(r: *const Resource, a: *const Action, e: Expr, d: *Diag) error{Invalid}!Kind {
    var i: usize = 0;
    return checkAt(r, a, e, &i, d);
}

fn checkAt(r: *const Resource, act: *const Action, e: Expr, i: *usize, d: *Diag) error{Invalid}!Kind {
    const node = e[i.*];
    i.* += 1;
    switch (node) {
        .value => |v| return switch (v) {
            .boolean => .boolean,
            .integer => .integer,
            .text => .text,
        },
        .ref => |n| {
            for (r.attributes) |a| if (eql(a.name, n)) return a.kind;
            return d.fail(&.{ "'", r.name, "' has no attribute '", n, "'" });
        },
        .arg => |g| {
            if (g.from.len > 0 and !eql(g.from, act.arguments_type))
                return d.fail(&.{ "argument '", g.name, "' is read from '", g.from, "', but the action's arguments are '", act.arguments_type, "'" });
            for (act.arguments) |a| if (eql(a.name, g.name)) return a.kind;
            return d.fail(&.{ "no argument '", g.name, "'" });
        },
        .call => |c| switch (c.op) {
            .eq, .gt => {
                const a = try checkAt(r, act, e, i, d);
                const b = try checkAt(r, act, e, i, d);
                if (a != b) return d.fail(&.{ "'", @tagName(c.op), "' compares ", @tagName(a), " with ", @tagName(b) });
                return .boolean;
            },
            .all => {
                for (0..c.arity) |_| {
                    const k = try checkAt(r, act, e, i, d);
                    if (k != .boolean) return d.fail(&.{ "'all' needs boolean operands, found ", @tagName(k) });
                }
                return .boolean;
            },
        },
    }
}

// ================================================================ printing

pub fn dump(e: Expr) void {
    for (e) |n| switch (n) {
        .ref => |x| std.debug.print("{s} ", .{x}),
        .arg => |x| std.debug.print("${s} ", .{x.name}),
        .value => |v| switch (v) {
            .boolean => |b| std.debug.print("{} ", .{b}),
            .integer => |k| std.debug.print("{d} ", .{k}),
            .text => |t| std.debug.print("'{s}' ", .{t}),
        },
        .call => |c| std.debug.print("{s}/{d} ", .{ @tagName(c.op), c.arity }),
    };
    std.debug.print("\n", .{});
}
