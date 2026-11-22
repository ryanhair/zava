//! PROTOTYPE, throwaway. Relationships as a sibling declaration.
const std = @import("std");

pub const Kind = enum { belongs_to, has_one, has_many };
pub fn Relationship(comptime R: type) type {
    return struct {
        name: [:0]const u8,
        kind: Kind,
        destination: type,
        /// belongs-to: the foreign key on the source, typed on the token.
        source_attribute: ?std.meta.FieldEnum(R) = null,
    };
}

const near_misses = .{ "relationship", "Relationships", "relations", "Relationship" };

fn list(comptime R: type) []const Relationship(R) {
    inline for (near_misses) |n| if (@hasDecl(R, n))
        @compileError(@typeName(R) ++ " declares '" ++ n ++ "'; relationships are read from a declaration named 'relationships'");
    if (!@hasDecl(R, "relationships")) return &.{};
    return R.relationships;
}
pub fn RelName(comptime R: type) type {
    const rels = list(R);
    if (rels.len == 0) return enum {};
    var names: [rels.len][:0]const u8 = undefined;
    for (rels, 0..) |r, i| names[i] = r.name;
    const Tag = std.math.IntFittingRange(0, rels.len - 1);
    const n = names;
    return @Enum(Tag, .exhaustive, &n, &std.simd.iota(Tag, rels.len));
}
fn rel(comptime R: type, comptime name: RelName(R)) Relationship(R) {
    for (list(R)) |r| if (std.mem.eql(u8, r.name, @tagName(name))) return r;
    unreachable;
}
fn Dest(comptime R: type, comptime name: RelName(R)) type {
    return rel(R, name).destination;
}

pub fn Term(comptime R: type, comptime V: type) type {
    return struct {
        n: u8,
        const Self = @This();
        pub fn value(_: V) Self {
            return .{ .n = 1 };
        }
        pub fn attr(comptime a: std.meta.FieldEnum(R)) Self {
            if (@FieldType(R, @tagName(a)) != V) @compileError("attribute of the wrong type");
            return .{ .n = 1 };
        }
        pub fn eq(comptime a: std.meta.FieldEnum(R), b: Term(R, @FieldType(R, @tagName(a)))) Term(R, bool) {
            return .{ .n = b.n + 2 };
        }
        pub fn all(terms: []const Self) Self {
            var n: u8 = 1;
            for (terms) |t| n += t.n;
            return .{ .n = n };
        }
        /// Existence test over a to-many relationship. The destination is not named.
        pub fn exists(comptime name: RelName(R), where: Term(Dest(R, name), bool)) Self {
            if (rel(R, name).kind != .has_many)
                @compileError("'" ++ @tagName(name) ++ "' is not a to-many relationship of " ++ @typeName(R) ++ "; an existence test needs one");
            return .{ .n = where.n + 1 };
        }
        /// Read through a to-one relationship.
        pub fn through(comptime name: RelName(R), inner: Term(Dest(R, name), V)) Self {
            if (rel(R, name).kind == .has_many)
                @compileError("'" ++ @tagName(name) ++ "' is a to-many relationship of " ++ @typeName(R) ++ "; reading through needs a to-one");
            return .{ .n = inner.n + 1 };
        }
    };
}

pub fn Action(comptime R: type) type {
    return struct {
        name: [:0]const u8,
        filter: ?Term(R, bool) = null,
        load: []const RelName(R) = &.{},
    };
}
pub fn Options(comptime R: type) type {
    return struct {
        primary_key: std.meta.FieldEnum(R),
        actions: []const Action(R) = &.{},
    };
}
pub fn count(comptime R: type) usize {
    return list(R).len;
}

pub fn ActionName(comptime R: type) type {
    const actions = R.resource.actions;
    if (actions.len == 0) return enum {};
    var names: [actions.len][:0]const u8 = undefined;
    for (actions, 0..) |a, i| names[i] = a.name;
    const Tag = std.math.IntFittingRange(0, actions.len - 1);
    const n = names;
    return @Enum(Tag, .exhaustive, &n, &std.simd.iota(Tag, actions.len));
}
pub const ActionKind = enum { create, read, update, destroy, generic };
pub fn Policy(comptime R: type) type {
    return struct {
        name: []const u8,
        on: union(enum) { all, kinds: []const ActionKind, actions: []const ActionName(R) },
        filter: ?Term(R, bool) = null,
        function: ?std.meta.DeclEnum(R) = null,
        bypass: bool = false,
    };
}
pub fn policies(comptime R: type) []const Policy(R) {
    if (!@hasDecl(R, "policies")) return &.{};
    return R.policies;
}
