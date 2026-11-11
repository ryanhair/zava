//! Kernel + "extension" code: comptime only. Never builds a type, never writes text.
const std = @import("std");
const api = @import("api"); // generated source (empty stub while the build step compiles)
const domain = @import("domain");

pub fn Action(comptime R: type) type {
    return struct { name: []const u8, accept: []const std.meta.FieldEnum(R), after: ?std.meta.DeclEnum(R) = null };
}

fn find(comptime R: type, comptime action: []const u8) Action(R) {
    for (R.actions) |a| if (std.mem.eql(u8, a.name, action)) return a;
    @compileError("no action " ++ action);
}

/// Type description: data, not a type. The kernel's one emitter turns it into source.
pub const Shape = struct { name: []const u8, field_names: []const []const u8, field_types: []const []const u8 };

pub fn inputShape(comptime R: type, comptime action: []const u8) Shape {
    const a = find(R, action);
    var names: [a.accept.len][]const u8 = undefined;
    var types: [a.accept.len][]const u8 = undefined;
    for (a.accept, 0..) |f, i| {
        names[i] = @tagName(f);
        types[i] = @typeName(@FieldType(R, @tagName(f)));
    }
    const n = names;
    const t = types;
    return .{ .name = pascal(action) ++ "Input", .field_names = &n, .field_types = &t };
}

pub fn pascal(comptime s: []const u8) []const u8 {
    return &[_]u8{std.ascii.toUpper(s[0])} ++ s[1..];
}

/// Look a generated type up by resource and shape name. Only evaluated in the app build.
pub fn Generated(comptime R: type, comptime shape: []const u8) type {
    return @field(@field(api, R.res_name), shape);
}

/// An "extension" derivation: a comptime value.
pub fn sql(comptime R: type, comptime action: []const u8) []const u8 {
    const a = find(R, action);
    var s: []const u8 = "update " ++ R.table ++ " set ";
    for (a.accept, 0..) |f, i| s = s ++ (if (i > 0) ", " else "") ++ @tagName(f) ++ " = $" ++ std.fmt.comptimePrint("{d}", .{i + 1});
    return s;
}

/// Comptime behaviour, typed on the generated input type.
pub fn run(comptime R: type, comptime action: []const u8, base: R, input: Generated(R, inputShape(R, action).name)) R {
    const a = comptime find(R, action);
    var r = base;
    inline for (a.accept) |f| @field(r, @tagName(f)) = @field(input, @tagName(f));
    if (a.after) |h| @field(R, @tagName(h))(&r, input);
    return r;
}

/// Comparison for question 3: the same behaviour written against concrete
/// generated types. Never referenced, so the stub graph does not analyse it.
pub fn runRegisterConcrete(base: domain.Author, input: api.Author.RegisterInput) domain.Author {
    var r = base;
    r.email = input.email;
    r.name = input.name;
    return r;
}

/// Half-way: `Generated` called with concrete arguments.
pub fn emailMixed(input: Generated(domain.Author, "RegisterInput")) []const u8 {
    return input.email;
}

/// A concrete alias written next to the generic code.
const RegisterInput = api.Author.RegisterInput;
pub fn nameAliased(in: RegisterInput) []const u8 {
    return in.name;
}
