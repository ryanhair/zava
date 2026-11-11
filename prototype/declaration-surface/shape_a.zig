//! PROTOTYPE, throwaway. Shape A: comptime data literals.
//! The declaration IS the normalized model; the frontend is three lines.
const core = @import("core.zig");

pub fn Resource(comptime spec: core.Res) type {
    @setEvalBranchQuota(100_000);
    core.validateRes(spec);
    return struct {
        pub const model = spec;
        pub const Record = core.RecordOf(spec);
    };
}

pub const Domain = core.Domain;
