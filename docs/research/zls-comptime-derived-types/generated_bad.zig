//! Deliberately wrong: one misspelled field, one misspelled action.
//! Separate functions with explicit return types, because the compiler stops at
//! the first error per function and an inferred error set would chain the failures.
const g = @import("generated.zig");

fn badField() void {
    const a = g.Author.register(.{ .emial = "x", .name = "y" }) catch return;
    _ = a;
}

fn badAction() void {
    const b = g.Author.regster(.{ .email = "x", .name = "y" }) catch return;
    _ = b;
}

pub fn main() void {
    badField();
    badAction();
}
