//! PROTOTYPE side probe. The alternative spelling: an extension's options as a sibling
//! declaration on the resource, found by the extension's name, instead of an entry in
//! `resource.extensions`. `zig run probe_sibling_declaration.zig`
const std = @import("std");

const postgres = struct {
    pub const name = "postgres";
    pub fn Options(comptime R: type) type {
        _ = R;
        return struct { table: []const u8 };
    }
};

pub const Author = struct {
    id: i64,
    // (a) The natural spelling does not compile: the declaration has the extension's name,
    //     so `postgres` inside the struct is ambiguous with the import.
    //     error: ambiguous reference
    // pub const postgres = postgres.Options(@This()){ .table = "authors" };

    // (b) So the import must be renamed, or the declaration named something else:
    pub const postgres_options = postgres.Options(@This()){ .table = "authors" };
};

pub const Post = struct {
    id: i64,
    // (c) A misspelled declaration name is silently ignored: the resource is just "not persisted".
    pub const postgres_optoins = postgres.Options(@This()){ .table = "posts" };
};

fn table(comptime R: type) ?[]const u8 {
    return if (@hasDecl(R, "postgres_options")) R.postgres_options.table else null;
}

pub fn main() void {
    std.debug.print("Author table: {?s}\nPost table:   {?s}   <- typo, no error\n", .{ table(Author), table(Post) });
}
