//! PROTOTYPE, throwaway. Shape C: builder functions.
//! Each call is one comptime step that returns a new builder value, and
//! checks what it can at that step.
const std = @import("std");
const core = @import("core.zig");

pub const AttrOpts = struct { primary_key: bool = false, generated: bool = false };

pub fn resource(comptime name: []const u8, comptime table: []const u8) Builder {
    return .{ .res = .{ .name = name, .table = table, .attributes = &.{} } };
}

pub const Builder = struct {
    res: core.Res,

    pub fn attribute(comptime self: Builder, comptime name: []const u8, comptime T: type, comptime opts: AttrOpts) Builder {
        if (core.findAttr(self.res, name) != null)
            @compileError("resource '" ++ self.res.name ++ "': duplicate attribute '" ++ name ++ "'");
        const a: core.Attr = .{ .name = name, .type = T, .primary_key = opts.primary_key, .generated = opts.generated };
        _ = core.sqlType(self.res, a);
        var r = self.res;
        r.attributes = r.attributes ++ &[_]core.Attr{a};
        return .{ .res = r };
    }

    pub fn belongsTo(comptime self: Builder, comptime name: []const u8, comptime destination: []const u8, comptime key: []const u8) Builder {
        if (core.findAttr(self.res, key) == null)
            @compileError("resource '" ++ self.res.name ++ "', relationship '" ++ name ++
                "': no attribute '" ++ key ++ "' to hold the key");
        return self.rel(.{ .name = name, .kind = .belongs_to, .destination = destination, .key = key });
    }

    pub fn hasMany(comptime self: Builder, comptime name: []const u8, comptime destination: []const u8, comptime key: []const u8) Builder {
        return self.rel(.{ .name = name, .kind = .has_many, .destination = destination, .key = key });
    }

    fn rel(comptime self: Builder, comptime r: core.Rel) Builder {
        var res = self.res;
        res.relationships = res.relationships ++ &[_]core.Rel{r};
        return .{ .res = res };
    }

    pub fn create(comptime self: Builder, comptime name: []const u8, comptime accept: []const []const u8) Builder {
        return self.action(.{ .name = name, .kind = .create, .accept = accept });
    }
    pub fn read(comptime self: Builder, comptime name: []const u8, comptime accept: []const []const u8) Builder {
        return self.action(.{ .name = name, .kind = .read, .accept = accept });
    }
    pub fn update(comptime self: Builder, comptime name: []const u8, comptime accept: []const []const u8) Builder {
        return self.action(.{ .name = name, .kind = .update, .accept = accept });
    }

    fn action(comptime self: Builder, comptime act: core.Action) Builder {
        for (act.accept) |name| {
            const a = core.findAttr(self.res, name) orelse
                @compileError("resource '" ++ self.res.name ++ "', action '" ++ act.name ++
                    "': accepts unknown attribute '" ++ name ++ "'");
            if (a.generated)
                @compileError("resource '" ++ self.res.name ++ "', action '" ++ act.name ++
                    "': cannot accept generated attribute '" ++ name ++ "'");
        }
        var res = self.res;
        res.actions = res.actions ++ &[_]core.Action{act};
        return .{ .res = res };
    }

    pub fn build(comptime self: Builder) type {
        @setEvalBranchQuota(100_000);
        core.validateRes(self.res);
        const spec = self.res;
        return struct {
            pub const model = spec;
            pub const Record = core.RecordOf(spec);
        };
    }
};

pub const Domain = core.Domain;
