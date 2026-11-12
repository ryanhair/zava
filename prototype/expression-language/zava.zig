//! PROTOTYPE, throwaway. Expression language: one representation, three spellings,
//! one checker and one lowering that both run at comptime and at runtime.
const std = @import("std");

// ================================================================ the representation
// An expression is a list of nodes in prefix order. Plain data: no types, no pointers
// between nodes, so the same value lives in the model, is built on the stack at a call
// site, and is built from a request, without an allocator.

pub const Kind = enum { boolean, integer, text };
pub const Value = union(enum) { boolean: bool, integer: i64, text: []const u8 };
pub const Op = enum { eq, ne, gt, ge, lt, le, all, any, not, add, sub };

pub const Node = union(enum) {
    /// An attribute or a calculation of the resource the expression is over.
    ref: []const u8,
    /// An argument of the action the expression belongs to.
    arg: []const u8,
    value: Value,
    /// Followed by `arity` operand expressions.
    call: struct { op: Op, arity: u8 },
    /// A to-many relationship; followed by one boolean expression over the destination.
    exists: []const u8,
    /// A to-one relationship; followed by one expression over the destination.
    related: []const u8,
};
pub const Expr = []const Node;

// ================================================================ the model (plain data)

pub const Attribute = struct { name: []const u8, kind: Kind };
pub const Relationship = struct { name: []const u8, many: bool, destination: []const u8, source_attribute: []const u8, destination_attribute: []const u8 };
pub const Calculation = struct { name: []const u8, kind: Kind, body: Expr };
pub const Argument = struct { name: []const u8, kind: Kind };
pub const Assignment = struct { attribute: []const u8, value: Expr };
pub const ActionKind = enum { read, update };
pub const Action = struct { name: []const u8, kind: ActionKind, arguments: []const Argument, filter: ?Expr, set: []const Assignment };
pub const Resource = struct {
    name: []const u8,
    table: []const u8,
    attributes: []const Attribute,
    relationships: []const Relationship,
    calculations: []const Calculation,
    actions: []const Action,

    pub fn action(r: *const Resource, name: []const u8) *const Action {
        for (r.actions) |*a| if (eql(a.name, name)) return a;
        unreachable;
    }
};
pub const Model = struct {
    resources: []const Resource,
    pub fn resource(m: *const Model, name: []const u8) *const Resource {
        for (m.resources) |*r| if (eql(r.name, name)) return r;
        unreachable;
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ================================================================ typed surface
// What a developer writes. A `Term(R, V)` is an expression over resource `R` whose result
// is a `V`. The compiler types it; what it holds is the untyped node list above.

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
/// The type an attribute is compared with: its own type, without the optional.
pub fn AttrType(comptime R: type, comptime a: Attr(R)) type {
    const T = @FieldType(R, @tagName(a));
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

pub fn kindOf(comptime T: type) Kind {
    if (T == []const u8) return .text;
    return switch (@typeInfo(T)) {
        .bool => .boolean,
        .int, .comptime_int => .integer,
        .@"enum" => .text,
        .optional => |o| kindOf(o.child),
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

pub const Comparison = enum { eq, ne, gt, ge, lt, le };

pub fn Term(comptime R: type, comptime V: type) type {
    return struct {
        any: Any,
        const Self = @This();

        fn mustBe(comptime T: type, comptime what: []const u8) void {
            if (V != T) @compileError(what ++ " gives " ++ @typeName(T) ++ ", but " ++ @typeName(V) ++ " is expected here");
        }

        // ---------------- operands

        pub fn value(v: V) Self {
            return .{ .any = .of(.{ .value = toValue(v) }, &.{}) };
        }
        pub fn attr(comptime a: Attr(R)) Self {
            comptime mustBe(AttrType(R, a), "attribute '" ++ @tagName(a) ++ "'");
            return .{ .any = .of(.{ .ref = @tagName(a) }, &.{}) };
        }
        /// Not typed here: the declaration is still being written. Checked when the model is lowered.
        pub fn calc(comptime name: @EnumLiteral()) Self {
            return .{ .any = .of(.{ .ref = @tagName(name) }, &.{}) };
        }
        /// Not typed here: a term does not know which action it is in. Checked when the model is lowered.
        pub fn arg(comptime name: @EnumLiteral()) Self {
            return .{ .any = .of(.{ .arg = @tagName(name) }, &.{}) };
        }
        pub fn add(a: Self, b: Self) Self {
            return .{ .any = .of(.{ .call = .{ .op = .add, .arity = 2 } }, &.{ a.any.expr(), b.any.expr() }) };
        }
        pub fn sub(a: Self, b: Self) Self {
            return .{ .any = .of(.{ .call = .{ .op = .sub, .arity = 2 } }, &.{ a.any.expr(), b.any.expr() }) };
        }
        /// Crosses a to-one relationship. The destination is named, because the relationship
        /// list is part of the declaration this expression is written inside.
        pub fn related(comptime D: type, comptime rel: @EnumLiteral(), t: Term(D, V)) Self {
            return .{ .any = .of(.{ .related = @tagName(rel) }, &.{t.any.expr()}) };
        }

        // ---------------- spelling A: prefix. Boolean terms, attribute on the left.

        fn compare(comptime op: Op, comptime a: Attr(R), rhs: Term(R, AttrType(R, a))) Self {
            comptime mustBe(bool, "a comparison");
            return .{ .any = .of(.{ .call = .{ .op = op, .arity = 2 } }, &.{ &.{.{ .ref = @tagName(a) }}, rhs.any.expr() }) };
        }
        pub fn eq(comptime a: Attr(R), rhs: Term(R, AttrType(R, a))) Self {
            return compare(.eq, a, rhs);
        }
        pub fn ne(comptime a: Attr(R), rhs: Term(R, AttrType(R, a))) Self {
            return compare(.ne, a, rhs);
        }
        pub fn gt(comptime a: Attr(R), rhs: Term(R, AttrType(R, a))) Self {
            return compare(.gt, a, rhs);
        }
        pub fn lt(comptime a: Attr(R), rhs: Term(R, AttrType(R, a))) Self {
            return compare(.lt, a, rhs);
        }
        /// The general comparison: either side is any term of type `T`.
        pub fn cmp(comptime T: type, comptime op: Comparison, lhs: Term(R, T), rhs: Term(R, T)) Self {
            comptime mustBe(bool, "a comparison");
            const o = comptime std.meta.stringToEnum(Op, @tagName(op)).?;
            return .{ .any = .of(.{ .call = .{ .op = o, .arity = 2 } }, &.{ lhs.any.expr(), rhs.any.expr() }) };
        }
        fn join(comptime op: Op, ts: []const Self) Self {
            comptime mustBe(bool, "'" ++ @tagName(op) ++ "'");
            var a: Any = .{};
            a.push(.{ .call = .{ .op = op, .arity = @intCast(ts.len) } });
            for (ts) |t| for (t.any.expr()) |n| a.push(n);
            return .{ .any = a };
        }
        pub fn all(ts: []const Self) Self {
            return join(.all, ts);
        }
        pub fn any_of(ts: []const Self) Self {
            return join(.any, ts);
        }
        pub fn not(t: Self) Self {
            return join(.not, &.{t});
        }
        /// Crosses a to-many relationship.
        pub fn exists(comptime D: type, comptime rel: @EnumLiteral(), where: Term(D, bool)) Self {
            comptime mustBe(bool, "'exists'");
            return .{ .any = .of(.{ .exists = @tagName(rel) }, &.{where.any.expr()}) };
        }

        // ---------------- spelling B: methods (see `of`). Only the boolean joins live here.

        pub fn andAlso(a: Self, b: Self) Self {
            return join(.all, &.{ a, b });
        }
        pub fn orElse(a: Self, b: Self) Self {
            return join(.any, &.{ a, b });
        }

        // ---------------- spelling C: a string, parsed at comptime. Nothing is typed here.

        pub fn parse(comptime source: []const u8) Self {
            comptime {
                @setEvalBranchQuota(100_000);
                var a: Any = .{};
                for (parser.parse(source)) |n| a.push(n);
                return .{ .any = a };
            }
        }
    };
}

/// Spelling B: `const p = zava.of(Post); p.attr(.views).gt(.value(10))`.
pub fn of(comptime R: type) type {
    return struct {
        pub fn attr(comptime a: Attr(R)) Operand(R, AttrType(R, a)) {
            return .{ .term = .attr(a) };
        }
        pub fn calc(comptime V: type, comptime name: @EnumLiteral()) Operand(R, V) {
            return .{ .term = .calc(name) };
        }
    };
}
pub fn Operand(comptime R: type, comptime V: type) type {
    return struct {
        term: Term(R, V),
        const Self = @This();
        pub fn eq(s: Self, rhs: Term(R, V)) Term(R, bool) {
            return .cmp(V, .eq, s.term, rhs);
        }
        pub fn gt(s: Self, rhs: Term(R, V)) Term(R, bool) {
            return .cmp(V, .gt, s.term, rhs);
        }
        pub fn lt(s: Self, rhs: Term(R, V)) Term(R, bool) {
            return .cmp(V, .lt, s.term, rhs);
        }
        pub fn plus(s: Self, rhs: Term(R, V)) Self {
            return .{ .term = .add(s.term, rhs) };
        }
    };
}

// ================================================================ spelling C: the parser
// Comptime only. `status == 'published' and views > $min_views`
//   or  := and ('or' and)*          and := not ('and' not)*        not := 'not' not | cmp
//   cmp := sum (==|!=|>|>=|<|<= sum)?                              sum := atom ((+|-) atom)*
//   atom := 123 | 'text' | true | false | $argument | name | relationship.name
//         | exists(relationship, or) | (or)

const parser = struct {
    fn fail(comptime src: []const u8, comptime pos: usize, comptime what: []const u8) noreturn {
        @compileError("expression \"" ++ src ++ "\": " ++ what ++ " at offset " ++ std.fmt.comptimePrint("{d}", .{pos}));
    }
    fn skip(comptime src: []const u8, comptime pos: *usize) void {
        while (pos.* < src.len and src[pos.*] == ' ') pos.* += 1;
    }
    fn isName(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }
    fn name(comptime src: []const u8, comptime pos: *usize) []const u8 {
        skip(src, pos);
        const start = pos.*;
        while (pos.* < src.len and isName(src[pos.*])) pos.* += 1;
        if (pos.* == start) fail(src, start, "expected a name");
        return src[start..pos.*];
    }
    /// Consumes `tok` if it is next. A word must not run into a longer name.
    fn take(comptime src: []const u8, comptime pos: *usize, comptime tok: []const u8) bool {
        skip(src, pos);
        if (!std.mem.startsWith(u8, src[pos.*..], tok)) return false;
        const end = pos.* + tok.len;
        if (isName(tok[0]) and end < src.len and isName(src[end])) return false;
        pos.* = end;
        return true;
    }
    fn call(comptime op: Op, comptime a: Expr, comptime b: Expr) Expr {
        return &[_]Node{.{ .call = .{ .op = op, .arity = 2 } }} ++ a ++ b;
    }

    fn parse(comptime src: []const u8) Expr {
        var pos: usize = 0;
        const e = parseOr(src, &pos);
        skip(src, &pos);
        if (pos != src.len) fail(src, pos, "unexpected text");
        return e;
    }
    fn parseOr(comptime src: []const u8, comptime pos: *usize) Expr {
        var e = parseAnd(src, pos);
        while (take(src, pos, "or")) e = call(.any, e, parseAnd(src, pos));
        return e;
    }
    fn parseAnd(comptime src: []const u8, comptime pos: *usize) Expr {
        var e = parseNot(src, pos);
        while (take(src, pos, "and")) e = call(.all, e, parseNot(src, pos));
        return e;
    }
    fn parseNot(comptime src: []const u8, comptime pos: *usize) Expr {
        if (take(src, pos, "not")) return &[_]Node{.{ .call = .{ .op = .not, .arity = 1 } }} ++ parseNot(src, pos);
        return parseCmp(src, pos);
    }
    fn parseCmp(comptime src: []const u8, comptime pos: *usize) Expr {
        const lhs = parseSum(src, pos);
        const ops = .{ .{ "==", Op.eq }, .{ "!=", Op.ne }, .{ ">=", Op.ge }, .{ "<=", Op.le }, .{ ">", Op.gt }, .{ "<", Op.lt } };
        for (ops) |o| if (take(src, pos, o[0])) return call(o[1], lhs, parseSum(src, pos));
        return lhs;
    }
    fn parseSum(comptime src: []const u8, comptime pos: *usize) Expr {
        var e = parseAtom(src, pos);
        while (true) {
            if (take(src, pos, "+")) {
                e = call(.add, e, parseAtom(src, pos));
            } else if (take(src, pos, "-")) {
                e = call(.sub, e, parseAtom(src, pos));
            } else return e;
        }
    }
    fn parseAtom(comptime src: []const u8, comptime pos: *usize) Expr {
        skip(src, pos);
        if (pos.* == src.len) fail(src, pos.*, "expected an operand");
        const c = src[pos.*];
        if (take(src, pos, "(")) {
            const e = parseOr(src, pos);
            if (!take(src, pos, ")")) fail(src, pos.*, "expected ')'");
            return e;
        }
        if (c == '\'') {
            const start = pos.* + 1;
            const end = std.mem.indexOfScalarPos(u8, src, start, '\'') orelse fail(src, pos.*, "unterminated text");
            pos.* = end + 1;
            return &.{.{ .value = .{ .text = src[start..end] } }};
        }
        if (std.ascii.isDigit(c)) {
            const start = pos.*;
            while (pos.* < src.len and std.ascii.isDigit(src[pos.*])) pos.* += 1;
            return &.{.{ .value = .{ .integer = std.fmt.parseInt(i64, src[start..pos.*], 10) catch unreachable } }};
        }
        if (c == '$') {
            pos.* += 1;
            return &.{.{ .arg = name(src, pos) }};
        }
        if (take(src, pos, "true")) return &.{.{ .value = .{ .boolean = true } }};
        if (take(src, pos, "false")) return &.{.{ .value = .{ .boolean = false } }};
        if (take(src, pos, "exists")) {
            if (!take(src, pos, "(")) fail(src, pos.*, "expected '('");
            const rel = name(src, pos);
            if (!take(src, pos, ",")) fail(src, pos.*, "expected ','");
            const e = parseOr(src, pos);
            if (!take(src, pos, ")")) fail(src, pos.*, "expected ')'");
            return &[_]Node{.{ .exists = rel }} ++ e;
        }
        const n = name(src, pos);
        if (take(src, pos, ".")) return &.{ .{ .related = n }, .{ .ref = name(src, pos) } };
        return &.{.{ .ref = n }};
    }
};

// ================================================================ the declaration

pub fn RelationshipEntry(comptime R: type) type {
    return struct { name: []const u8, kind: enum { belongs_to, has_many }, destination: type, source_attribute: Attr(R), destination_attribute: []const u8 };
}
pub fn CalculationEntry(comptime R: type) type {
    return struct {
        name: []const u8,
        kind: Kind,
        body: Any,
        pub fn calc(name: []const u8, comptime V: type, body: Term(R, V)) @This() {
            return .{ .name = name, .kind = kindOf(V), .body = body.any };
        }
    };
}
pub const ArgumentEntry = struct { name: []const u8, type: type };
pub fn AssignmentEntry(comptime R: type) type {
    return struct {
        attribute: []const u8,
        value: Any,
        /// An atomic update: the new value of attribute `a` is an expression.
        pub fn to(comptime a: Attr(R), value: Term(R, AttrType(R, a))) @This() {
            return .{ .attribute = @tagName(a), .value = value.any };
        }
    };
}
pub fn ActionEntry(comptime R: type) type {
    return struct {
        name: []const u8,
        kind: ActionKind = .read,
        arguments: []const ArgumentEntry = &.{},
        filter: ?Term(R, bool) = null,
        set: []const AssignmentEntry(R) = &.{},
    };
}
pub fn Options(comptime R: type) type {
    return struct {
        name: []const u8,
        table: []const u8,
        relationships: []const RelationshipEntry(R) = &.{},
        calculations: []const CalculationEntry(R) = &.{},
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
        const names = @typeInfo(R).@"struct".field_names;
        var attributes: [names.len]Attribute = undefined;
        for (names, 0..) |n, i| attributes[i] = .{ .name = n, .kind = kindOf(@FieldType(R, n)) };
        var relationships: [decl.relationships.len]Relationship = undefined;
        for (decl.relationships, 0..) |r, i| relationships[i] = .{
            .name = r.name,
            .many = r.kind == .has_many,
            .destination = @as(Options(r.destination), r.destination.resource).name,
            .source_attribute = @tagName(r.source_attribute),
            .destination_attribute = r.destination_attribute,
        };
        var calculations: [decl.calculations.len]Calculation = undefined;
        for (decl.calculations, 0..) |c, i| calculations[i] = .{ .name = c.name, .kind = c.kind, .body = fixed(c.body) };
        var actions: [decl.actions.len]Action = undefined;
        for (decl.actions, 0..) |a, i| {
            var arguments: [a.arguments.len]Argument = undefined;
            for (a.arguments, 0..) |g, j| arguments[j] = .{ .name = g.name, .kind = kindOf(g.type) };
            var set: [a.set.len]Assignment = undefined;
            for (a.set, 0..) |s, j| set[j] = .{ .attribute = s.attribute, .value = fixed(s.value) };
            const ar = arguments;
            const se = set;
            actions[i] = .{ .name = a.name, .kind = a.kind, .arguments = &ar, .filter = if (a.filter) |f| fixed(f.any) else null, .set = &se };
        }
        const at = attributes;
        const re = relationships;
        const ca = calculations;
        const ac = actions;
        return .{ .name = decl.name, .table = decl.table, .attributes = &at, .relationships = &re, .calculations = &ca, .actions = &ac };
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
        for (m.resources) |*r| {
            for (r.calculations) |c| expect(&m, r, &.{}, c.body, c.kind, r.name ++ ", calculation '" ++ c.name ++ "'");
            for (r.actions) |a| {
                if (a.filter) |f| expect(&m, r, a.arguments, f, .boolean, r.name ++ ", action '" ++ a.name ++ "', filter");
                for (a.set) |s| {
                    const want = for (r.attributes) |at| {
                        if (eql(at.name, s.attribute)) break at.kind;
                    } else unreachable;
                    expect(&m, r, a.arguments, s.value, want, r.name ++ ", action '" ++ a.name ++ "', set '" ++ s.attribute ++ "'");
                }
            }
        }
        return m;
    }
}

fn expect(comptime m: *const Model, comptime r: *const Resource, comptime args: []const Argument, comptime e: Expr, comptime want: Kind, comptime where: []const u8) void {
    var d: Diag = .{};
    const got = check(m, r, args, e, &d) catch @compileError(where ++ ": " ++ d.message());
    if (got != want) @compileError(where ++ ": the expression is " ++ @tagName(got) ++ ", expected " ++ @tagName(want));
}

// ================================================================ the checker
// One function. Runs at comptime on declared expressions and at runtime on expressions
// built from a request.

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

pub fn check(m: *const Model, r: *const Resource, args: []const Argument, e: Expr, d: *Diag) error{Invalid}!Kind {
    var i: usize = 0;
    return checkAt(m, r, args, e, &i, d);
}

fn checkAt(m: *const Model, r: *const Resource, args: []const Argument, e: Expr, i: *usize, d: *Diag) error{Invalid}!Kind {
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
            for (r.calculations) |c| if (eql(c.name, n)) return c.kind;
            return d.fail(&.{ "'", r.name, "' has no attribute or calculation '", n, "'" });
        },
        .arg => |n| {
            for (args) |a| if (eql(a.name, n)) return a.kind;
            return d.fail(&.{ "no argument '", n, "'" });
        },
        .call => |c| switch (c.op) {
            .eq, .ne, .gt, .ge, .lt, .le => {
                const a = try checkAt(m, r, args, e, i, d);
                const b = try checkAt(m, r, args, e, i, d);
                if (a != b) return d.fail(&.{ "'", @tagName(c.op), "' compares ", @tagName(a), " with ", @tagName(b) });
                if (a == .boolean and c.op != .eq and c.op != .ne) return d.fail(&.{ "'", @tagName(c.op), "' cannot order booleans" });
                return .boolean;
            },
            .all, .any, .not => {
                for (0..c.arity) |_| {
                    const k = try checkAt(m, r, args, e, i, d);
                    if (k != .boolean) return d.fail(&.{ "'", @tagName(c.op), "' needs boolean operands, found ", @tagName(k) });
                }
                return .boolean;
            },
            .add, .sub => {
                for (0..c.arity) |_| {
                    const k = try checkAt(m, r, args, e, i, d);
                    if (k != .integer) return d.fail(&.{ "'", @tagName(c.op), "' needs integer operands, found ", @tagName(k) });
                }
                return .integer;
            },
        },
        .exists, .related => |n| {
            const rel = for (r.relationships) |*x| {
                if (eql(x.name, n)) break x;
            } else return d.fail(&.{ "'", r.name, "' has no relationship '", n, "'" });
            const dest = m.resource(rel.destination);
            if (node == .exists) {
                if (!rel.many) return d.fail(&.{ "'exists' needs a to-many relationship; '", n, "' is to-one" });
                const k = try checkAt(m, dest, args, e, i, d);
                if (k != .boolean) return d.fail(&.{ "'exists' needs a boolean expression, found ", @tagName(k) });
                return .boolean;
            }
            if (rel.many) return d.fail(&.{ "'", n, "' is to-many; only a to-one relationship can be read through" });
            return checkAt(m, dest, args, e, i, d);
        },
    }
}

// ================================================================ the lowering (data layer's job)
// One function. Statement text for a declared expression is a comptime constant; for an
// expression built at runtime the same function writes it at runtime. Values never enter
// the text: every literal and argument becomes a parameter.

pub const Param = union(enum) { value: Value, arg: []const u8 };

pub const Sql = struct {
    text: [1024]u8 = undefined,
    len: usize = 0,
    params: [16]Param = undefined,
    count: usize = 0,
    aliases: usize = 0,

    fn add(s: *Sql, str: []const u8) void {
        @memcpy(s.text[s.len..][0..str.len], str);
        s.len += str.len;
    }
    fn num(s: *Sql, v: usize) void {
        if (v >= 10) s.num(v / 10);
        s.add(&.{'0' + @as(u8, @intCast(v % 10))});
    }
    fn param(s: *Sql, p: Param) void {
        s.params[s.count] = p;
        s.count += 1;
        s.add("$");
        s.num(s.count);
    }
    fn column(s: *Sql, alias: usize, name: []const u8) void {
        s.add("t");
        s.num(alias);
        s.add(".");
        s.add(name);
    }
};

fn sqlOp(op: Op) []const u8 {
    return switch (op) {
        .eq => " = ",
        .ne => " <> ",
        .gt => " > ",
        .ge => " >= ",
        .lt => " < ",
        .le => " <= ",
        .all => " and ",
        .any => " or ",
        .add => " + ",
        .sub => " - ",
        .not => unreachable,
    };
}

fn lowerAt(m: *const Model, r: *const Resource, alias: usize, e: Expr, i: *usize, s: *Sql) void {
    const node = e[i.*];
    i.* += 1;
    switch (node) {
        .value => |v| s.param(.{ .value = v }),
        .arg => |n| s.param(.{ .arg = n }),
        .ref => |n| {
            for (r.calculations) |c| if (eql(c.name, n)) {
                var j: usize = 0;
                return lowerAt(m, r, alias, c.body, &j, s); // a calculation is inlined
            };
            s.column(alias, n);
        },
        .call => |c| {
            if (c.op == .not) {
                s.add("not ");
                return lowerAt(m, r, alias, e, i, s);
            }
            s.add("(");
            for (0..c.arity) |k| {
                if (k > 0) s.add(sqlOp(c.op));
                lowerAt(m, r, alias, e, i, s);
            }
            s.add(")");
        },
        .exists, .related => |n| {
            const rel = for (r.relationships) |*x| {
                if (eql(x.name, n)) break x;
            } else unreachable;
            const dest = m.resource(rel.destination);
            s.aliases += 1;
            const inner = s.aliases;
            const from = struct {
                fn f(sq: *Sql, de: *const Resource, re: *const Relationship, in: usize, out: usize) void {
                    sq.add(" from ");
                    sq.add(de.table);
                    sq.add(" t");
                    sq.num(in);
                    sq.add(" where ");
                    sq.column(in, re.destination_attribute);
                    sq.add(" = ");
                    sq.column(out, re.source_attribute);
                }
            }.f;
            if (node == .exists) {
                s.add("exists (select 1");
                from(s, dest, rel, inner, alias);
                s.add(" and ");
                lowerAt(m, dest, inner, e, i, s);
            } else {
                s.add("(select ");
                var probe: Sql = .{ .count = s.count, .aliases = s.aliases };
                lowerAt(m, dest, inner, e, i, &probe); // lowered once to find its text, then placed
                s.add(probe.text[0..probe.len]);
                for (probe.params[s.count..probe.count]) |p| {
                    s.params[s.count] = p;
                    s.count += 1;
                }
                from(s, dest, rel, inner, alias);
            }
            s.add(")");
        },
    }
}

/// `select` for a read: every filter is and-ed.
pub fn select(m: *const Model, r: *const Resource, filters: []const Expr) Sql {
    var s: Sql = .{};
    s.add("select t0.* from ");
    s.add(r.table);
    s.add(" t0");
    for (filters, 0..) |f, k| {
        s.add(if (k == 0) " where " else " and ");
        var i: usize = 0;
        lowerAt(m, r, 0, f, &i, &s);
    }
    return s;
}

/// `update` by primary key, with the action's atomic assignments.
pub fn update(m: *const Model, r: *const Resource, a: *const Action) Sql {
    var s: Sql = .{};
    s.add("update ");
    s.add(r.table);
    s.add(" t0 set ");
    for (a.set, 0..) |as, k| {
        if (k > 0) s.add(", ");
        s.add(as.attribute);
        s.add(" = ");
        var i: usize = 0;
        lowerAt(m, r, 0, as.value, &i, &s);
    }
    s.add(" where t0.id = ");
    s.param(.{ .arg = "id" });
    return s;
}

pub const Statement = struct { text: []const u8, params: []const Param };
/// Freezes a statement built at comptime into constants.
pub fn statement(comptime s: Sql) Statement {
    const t = s.text[0..s.len].*;
    const p = s.params[0..s.count].*;
    return .{ .text = &t, .params = &p };
}

// ================================================================ built from a request
// `views.gt=10&status.eq=published`. Runtime only; the model is fixed, the values vary.

pub fn fromQuery(m: *const Model, r: *const Resource, query: []const u8, buf: []Node, d: *Diag) error{Invalid}!Expr {
    var len: usize = 1;
    var terms: u8 = 0;
    var parts = std.mem.splitScalar(u8, query, '&');
    while (parts.next()) |part| {
        const dot = std.mem.indexOfScalar(u8, part, '.') orelse return d.fail(&.{ "'", part, "' is not attribute.operator=value" });
        const equals = std.mem.indexOfScalar(u8, part, '=') orelse return d.fail(&.{ "'", part, "' is not attribute.operator=value" });
        const name = part[0..dot];
        const op = std.meta.stringToEnum(Comparison, part[dot + 1 .. equals]) orelse return d.fail(&.{ "unknown operator '", part[dot + 1 .. equals], "'" });
        const raw = part[equals + 1 ..];
        const kind = for (r.attributes) |a| {
            if (eql(a.name, name)) break a.kind;
        } else return d.fail(&.{ "'", r.name, "' has no attribute '", name, "'" });
        const value: Value = switch (kind) {
            .integer => .{ .integer = std.fmt.parseInt(i64, raw, 10) catch return d.fail(&.{ "attribute '", name, "' is integer; '", raw, "' is not" }) },
            .boolean => .{ .boolean = if (eql(raw, "true")) true else if (eql(raw, "false")) false else return d.fail(&.{ "attribute '", name, "' is boolean; '", raw, "' is not" }) },
            .text => .{ .text = raw },
        };
        buf[len] = .{ .call = .{ .op = std.meta.stringToEnum(Op, @tagName(op)).?, .arity = 2 } };
        buf[len + 1] = .{ .ref = name };
        buf[len + 2] = .{ .value = value };
        len += 3;
        terms += 1;
    }
    buf[0] = .{ .call = .{ .op = .all, .arity = terms } };
    const e = buf[0..len];
    _ = try check(m, r, &.{}, e, d); // the same checker the build runs
    return e;
}

// ================================================================ printing

pub fn dump(e: Expr) void {
    for (e) |n| switch (n) {
        .ref => |x| std.debug.print("{s} ", .{x}),
        .arg => |x| std.debug.print("${s} ", .{x}),
        .value => |v| printValue(v),
        .call => |c| std.debug.print("{s}/{d} ", .{ @tagName(c.op), c.arity }),
        .exists => |x| std.debug.print("exists:{s} ", .{x}),
        .related => |x| std.debug.print("related:{s} ", .{x}),
    };
    std.debug.print("\n", .{});
}
fn printValue(v: Value) void {
    switch (v) {
        .boolean => |b| std.debug.print("{} ", .{b}),
        .integer => |n| std.debug.print("{d} ", .{n}),
        .text => |t| std.debug.print("'{s}' ", .{t}),
    }
}
pub fn show(label: []const u8, text: []const u8, params: []const Param) void {
    std.debug.print("{s}\n  sql     {s}\n  params  ", .{ label, text });
    for (params, 1..) |p, n| {
        std.debug.print("${d}=", .{n});
        switch (p) {
            .arg => |a| std.debug.print("argument {s}  ", .{a}),
            .value => |v| printValue(v),
        }
    }
    std.debug.print("\n\n", .{});
}
