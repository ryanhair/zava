//! PROTOTYPE probe. Does the move reach calculation and relationship names?
//! Variant "split": relationships and calculations leave `resource` and become their own
//! declarations, so an expression in `resource` can read them without a dependency loop.
const std = @import("std");

fn enumOf(comptime names: []const []const u8) type {
    if (names.len == 0) return enum {};
    const Tag = std.math.IntFittingRange(0, names.len - 1);
    return @Enum(Tag, .exhaustive, names, &std.simd.iota(Tag, names.len));
}
fn RelName(comptime R: type) type {
    var names: []const []const u8 = &.{};
    for (R.relationships) |r| names = names ++ &[_][]const u8{r.name};
    return enumOf(names);
}
fn Dest(comptime R: type, comptime rel: RelName(R)) type {
    for (R.relationships) |r| if (std.mem.eql(u8, r.name, @tagName(rel))) return r.destination;
    unreachable;
}
/// The calculations of `R` whose type is `V`.
fn CalcName(comptime R: type, comptime V: type) type {
    var names: []const []const u8 = &.{};
    for (R.calculations) |c| if (c.type == V) {
        names = names ++ &[_][]const u8{c.name};
    };
    return enumOf(names);
}

fn Term(comptime R: type, comptime V: type) type {
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
        pub fn calc(comptime c: CalcName(R, V)) Self {
            _ = c;
            return .{ .n = 1 };
        }
        pub fn add(a: Self, b: Self) Self {
            return .{ .n = a.n + b.n + 1 };
        }
        pub fn gt(comptime T: type, a: Term(R, T), b: Term(R, T)) Self {
            return .{ .n = a.n + b.n + 1 };
        }
        pub fn exists(comptime rel: RelName(R), where: Term(Dest(R, rel), bool)) Self {
            return .{ .n = where.n + 1 };
        }
    };
}

const Relationship = struct { name: []const u8, destination: type };
fn Calculation(comptime R: type) type {
    return struct {
        name: []const u8,
        type: type,
        n: u8,
        pub fn of(name: []const u8, comptime V: type, body: Term(R, V)) @This() {
            return .{ .name = name, .type = V, .n = body.n };
        }
    };
}
fn Options(comptime R: type) type {
    return struct { filter: ?Term(R, bool) = null };
}

const Comment = struct {
    post_id: i64,
    flagged: bool,
    pub const relationships: []const Relationship = &.{.{ .name = "post", .destination = Post }};
    pub const calculations: []const Calculation(@This()) = &.{};
};
const Post = struct {
    id: i64,
    views: i64,
    likes: i64,

    pub const relationships: []const Relationship = &.{.{ .name = "comments", .destination = Comment }};
    pub const calculations: []const Calculation(@This()) = &.{
        .of("popularity", i64, .add(.attr(.views), .attr(.likes))),
        // A calculation that crosses a relationship: fine.
        .of("discussed", bool, .exists(.comments, .attr(.flagged))),
        // CALC-TO-CALC .of("hot", bool, .gt(i64, .calc(.popularity), .value(100))),
    };
    pub const resource: Options(@This()) = .{
        .filter = .add(
            .gt(i64, .calc(.popularity), .value(100)),
            .exists(.comments, .attr(.flagged)),
        ),
    };
};

pub fn main() void {
    std.debug.print("split: filter has {} nodes\n", .{Post.resource.filter.?.n});
}
