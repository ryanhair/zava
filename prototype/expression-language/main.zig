//! PROTOTYPE, throwaway. Run: `zig run main.zig`
const std = @import("std");
const zava = @import("zava.zig");
const domain = @import("domain.zig");

const model: zava.Model = zava.model(domain.resources); // lowered and checked at comptime
const post = model.resource("post");

pub fn main() void {
    const print = std.debug.print;

    print("=== 1. Declared in the resource: statement text is a comptime constant\n\n", .{});
    inline for (.{ "popular_a", "popular_b", "popular_c", "trending_a", "trending_b", "trending_c", "trending_loose" }) |name| {
        const st = comptime blk: {
            @setEvalBranchQuota(100_000); // the quota is per comptime entry point
            break :blk zava.statement(zava.select(&model, post, &.{post.action(name).filter.?}));
        };
        zava.show(name, st.text, st.params);
    }
    print("the representation of popular_a, as stored in the model:\n  ", .{});
    zava.dump(post.action("popular_a").filter.?);
    print("the representation of trending_c:\n  ", .{});
    zava.dump(post.action("trending_c").filter.?);

    print("\n=== 2. An expression in a change (atomic update), also a comptime constant\n\n", .{});
    const up = comptime blk: {
        @setEvalBranchQuota(100_000);
        break :blk zava.statement(zava.update(&model, post, post.action("view")));
    };
    zava.show("view", up.text, up.params);

    print("=== 3. Written at a call site with a runtime value, and-ed with the declared filter\n\n", .{});
    var min_likes: i64 = 3;
    _ = &min_likes;
    const extra: zava.Term(domain.Post, bool) = .all(&.{ .gt(.likes, .value(min_likes)), .eq(.featured, .value(true)) });
    const s3 = zava.select(&model, post, &.{ post.action("popular_a").filter.?, extra.any.expr() });
    zava.show("popular_a + caller's filter", s3.text[0..s3.len], s3.params[0..s3.count]);

    print("=== 4. Built from a request at runtime: same representation, same checker, same lowering\n\n", .{});
    const queries = [_][]const u8{
        "views.gt=10&status.eq=published",
        "title.eq=x' or 1=1 --",
        "viewz.gt=10",
        "views.gt=ten",
        "featured.gt=true",
    };
    for (queries) |q| {
        var buf: [64]zava.Node = undefined;
        var d: zava.Diag = .{};
        if (zava.fromQuery(&model, post, q, &buf, &d)) |e| {
            const s = zava.select(&model, post, &.{e});
            zava.show(q, s.text[0..s.len], s.params[0..s.count]);
        } else |_| {
            print("{s}\n  rejected  {s}\n\n", .{ q, d.message() });
        }
    }
}
