const std = @import("std");

// `zig build check` compiles all the probe files. ZLS build-on-save runs this step.
// The *_bad files are expected to fail; pass -Dbad=false to leave them out.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const bad = b.option(bool, "bad", "include the deliberately broken files") orelse true;
    const check = b.step("check", "Compile the probe files without installing");
    const good: []const []const u8 = &.{ "derived", "generated", "variations" };
    const broken: []const []const u8 = &.{ "derived_bad", "generated_bad" };
    for (good) |name| add(b, check, target, name);
    if (bad) for (broken) |name| add(b, check, target, name);
}

fn add(b: *std.Build, check: *std.Build.Step, target: std.Build.ResolvedTarget, name: []const u8) void {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("{s}.zig", .{name})),
            .target = target,
        }),
    });
    check.dependOn(&exe.step);
}
