//! PROTOTYPE probe. Does the move reach calculation and relationship names?
//! Variant "types": the same move as shape 1. The names and types of calculations and
//! relationships are struct types beside the record; `resource` keeps their bodies and
//! options in blocks keyed by name, as per-attribute options already are.
const std = @import("std");

fn Many(comptime D: type) type {
    return struct {
        pub const destination = D;
    };
}

/// The fields of `S` whose type is `V`, as an enum.
fn NamesOf(comptime S: type, comptime V: type) type {
    var names: []const []const u8 = &.{};
    for (std.meta.fieldNames(S)) |n| if (@FieldType(S, n) == V) {
        names = names ++ &[_][]const u8{n};
    };
    if (names.len == 0) return enum {};
    const Tag = std.math.IntFittingRange(0, names.len - 1);
    return @Enum(Tag, .exhaustive, names, &std.simd.iota(Tag, names.len));
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
        pub fn calc(comptime c: NamesOf(R.Calculated, V)) Self {
            _ = c;
            return .{ .n = 1 };
        }
        pub fn add(a: Self, b: Self) Self {
            return .{ .n = a.n + b.n + 1 };
        }
        pub fn gt(comptime T: type, a: Term(R, T), b: Term(R, T)) Self {
            return .{ .n = a.n + b.n + 1 };
        }
        pub fn exists(comptime rel: std.meta.FieldEnum(R.Related), where: Term(@FieldType(R.Related, @tagName(rel)).destination, bool)) Self {
            return .{ .n = where.n + 1 };
        }
    };
}

/// One body per field of `R.Calculated`, typed by that field.
fn CalculationsBlock(comptime R: type) type {
    const names = std.meta.fieldNames(R.Calculated);
    var types: [names.len]type = undefined;
    for (names, 0..) |n, i| types[i] = Term(R, @FieldType(R.Calculated, n));
    const t = types;
    return @Struct(.auto, null, names, &t, &@splat(.{}));
}
fn Options(comptime R: type) type {
    return struct { calculations: CalculationsBlock(R), filter: ?Term(R, bool) = null };
}

const Comment = struct {
    post_id: i64,
    flagged: bool,
    pub const Calculated = struct {};
    pub const Related = struct { post: Many(Post) }; // mutual reference: fine
    pub const resource: Options(@This()) = .{ .calculations = .{} };
};
const Post = struct {
    id: i64,
    views: i64,
    likes: i64,

    pub const Calculated = struct { popularity: i64, discussed: bool, hot: bool };
    pub const Related = struct { comments: Many(Comment) };

    pub const resource: Options(@This()) = .{
        .calculations = .{
            .popularity = .add(.attr(.views), .attr(.likes)),
            .discussed = .exists(.comments, .attr(.flagged)),
            // A calculation that reads a calculation: fine here.
            .hot = .gt(i64, .calc(.popularity), .value(100)),
        },
        .filter = .add(
            .gt(i64, .calc(.popularity), .value(100)),
            .exists(.comments, .attr(.flagged)),
        ),
    };
};

pub fn main() void {
    std.debug.print("types: filter has {} nodes, hot has {} nodes\n", .{ Post.resource.filter.?.n, Post.resource.calculations.hot.n });
}
