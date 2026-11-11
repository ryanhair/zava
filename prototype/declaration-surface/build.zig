//! PROTOTYPE, throwaway. `zig build run` shows all four shapes;
//! `zig build gen` prints the source shape D generates.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.graph.host;

    // Shapes A, B, C: nothing but comptime.
    const abc = b.addExecutable(.{
        .name = "abc",
        .root_module = b.createModule(.{ .root_source_file = b.path("main_abc.zig"), .target = target }),
    });

    // Shape D: the generator imports the domain module, its stdout becomes a module.
    const gen_mod = b.createModule(.{ .root_source_file = b.path("gen.zig"), .target = target });
    gen_mod.addAnonymousImport("domain", .{ .root_source_file = b.path("domain_d.zig") });
    const gen = b.addExecutable(.{ .name = "gen", .root_module = gen_mod });
    const generated = b.addRunArtifact(gen).captureStdOut(.{ .basename = "generated.zig" });

    const app_mod = b.createModule(.{ .root_source_file = b.path("app_d.zig"), .target = target });
    app_mod.addAnonymousImport("generated", .{ .root_source_file = generated });
    const app = b.addExecutable(.{ .name = "app_d", .root_module = app_mod });

    const run = b.step("run", "Show all four shapes");
    const run_abc = b.addRunArtifact(abc);
    const run_d = b.addRunArtifact(app);
    run_d.step.dependOn(&run_abc.step);
    run.dependOn(&run_d.step);

    const show = b.step("gen", "Print the source shape D generates");
    show.dependOn(&b.addRunArtifact(gen).step);
}
