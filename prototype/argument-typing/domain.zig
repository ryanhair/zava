//! PROTOTYPE, throwaway. What the developer writes. The same read action in three shapes.
const zava = @import("zava.zig");

pub const Status = enum { draft, published };

pub const Post = struct {
    id: i64,
    title: []const u8,
    status: Status,
    views: i64,

    // Shape 2 needs the arguments as a named type, written outside the declaration.
    pub const PopularArguments = struct { min_views: i64 };
    pub const RecentArguments = struct { min_views: i64, since: i64 };

    pub const resource = zava.Options(@This()){
        .name = "post",
        .actions = &.{
            // ---- shape 0, current: arguments are a list; `.arg` takes any name
            .{
                .name = "popular_0",
                .arguments = &.{.{ .name = "min_views", .type = i64, .min = 0 }},
                .filter = .all(&.{
                    .eq(.status, .value(.published)),
                    .gt(.views, .arg(.min_views)),
                }),
            },

            // ---- shape 1: the action is a function call; arguments are a struct type
            .read("popular_1", struct { min_views: i64 }, .{
                .arguments = .{ .min_views = .{ .min = 0 } },
                .filter = .all(&.{
                    .eq(.status, .value(.published)),
                    .gt(.views, .arg(.min_views)),
                }),
            }),

            // ---- shape 2: the entry is unchanged; the arguments type is named at the argument
            .{
                .name = "popular_2",
                .args = PopularArguments,
                .filter = .all(&.{
                    .eq(.status, .value(.published)),
                    .gt(.views, .argOf(PopularArguments, .min_views)),
                }),
            },
        },
    };
};

pub const resources = .{Post};
