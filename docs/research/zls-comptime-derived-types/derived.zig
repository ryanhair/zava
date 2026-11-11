//! Comptime-derived surface: the domain is declared as annotated structs and
//! the action enum and input structs are built with @Enum / @Struct.
const std = @import("std");

pub const Action = struct { name: [:0]const u8, accept: []const [:0]const u8 };

pub const Author = struct {
    id: i64,
    email: []const u8,
    name: []const u8,
    pub const actions: []const Action = &.{
        .{ .name = "register", .accept = &.{ "email", "name" } },
        .{ .name = "rename", .accept = &.{"name"} },
    };
};

pub const Post = struct {
    id: i64,
    author_id: i64,
    title: []const u8,
    body: ?[]const u8,
    published: bool,
    pub const actions: []const Action = &.{
        .{ .name = "draft", .accept = &.{ "author_id", "title", "body" } },
        .{ .name = "publish", .accept = &.{"published"} },
    };
};

pub fn ActionName(comptime R: type) type {
    var names: [R.actions.len][]const u8 = undefined;
    for (R.actions, 0..) |a, i| names[i] = a.name;
    return @Enum(u8, .exhaustive, &names, &std.simd.iota(u8, R.actions.len));
}

pub fn Input(comptime R: type, comptime action: ActionName(R)) type {
    const a = R.actions[@intFromEnum(action)];
    var names: [a.accept.len][]const u8 = undefined;
    var types: [a.accept.len]type = undefined;
    for (a.accept, 0..) |n, i| {
        names[i] = n;
        types[i] = @FieldType(R, n);
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

pub const Error = error{ Invalid, Forbidden, Conflict };

pub fn run(comptime R: type, comptime action: ActionName(R), input: Input(R, action)) Error!R {
    var r: R = undefined;
    r.id = 1;
    inline for (@typeInfo(@TypeOf(input)).@"struct".field_names) |n| @field(r, n) = @field(input, n);
    return r;
}

/// Variation: the derived types reached through a namespace function.
pub fn Api(comptime R: type) type {
    return struct {
        pub const Name = ActionName(R);
        pub fn In(comptime action: Name) type {
            return Input(R, action);
        }
        pub fn call(comptime action: Name, input: Input(R, action)) Error!R {
            return run(R, action, input);
        }
    };
}

/// Variation: a named alias for the derived type.
pub const RegisterInput = Input(Author, .register);

// user-written, fully typed hook: no anytype
fn normalize(input: *Input(Author, .register)) void {
    input.name = "Ann";
}

fn normalizeAlias(input: *RegisterInput) void {
    input.name = "Ann";
}

// Control: the user-written record struct as a parameter type.
fn control(author: Author) []const u8 {
    return author.name;
}

pub fn main() !void {
    var in: Input(Author, .register) = .{ .email = "a@b.c", .name = "ann" };
    normalize(&in);
    const a = try run(Author, .register, in);
    _ = in.email;
    _ = a.email;
    const lit = try run(Author, .register, .{ .email = "x", .name = "y" });
    _ = lit;

    const post_in: Input(Post, .publish) = .{ .published = true };
    const p = try run(Post, .publish, post_in);
    _ = p.title;
    const d = try run(Post, .draft, .{ .author_id = 1, .title = "t", .body = null });
    _ = d;

    var aliased: RegisterInput = .{ .email = "a@b.c", .name = "ann" };
    normalizeAlias(&aliased);
    _ = aliased.email;

    const ns_in: Api(Author).In(.register) = .{ .email = "a@b.c", .name = "ann" };
    _ = ns_in.email;
    const ns_a = try Api(Author).call(.register, ns_in);
    _ = ns_a.email;
    const AuthorApi = Api(Author);
    const ns_b = try AuthorApi.call(.rename, .{ .name = "z" });
    _ = ns_b;

    _ = control(a);
    std.debug.print("{s} {s}\n", .{ a.email, a.name });
}
