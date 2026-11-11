const std = @import("std");

// The driver rewrites these three lines to select a configuration.
const mode: Mode = .capture;
const with_check = true;
const graph: Graph = .stub;

const Graph = enum {
    /// The prototype's wiring: the generator's copy of domain/zava imports an empty stub as `api`.
    stub,
    /// The generator's copy of domain/zava has no `api` import at all. This compiles because
    /// nothing the generator analyses reaches `@import("api")` (declarations are lazy).
    no_stub,
    /// Stub kept, but the app is installed first and imports domain and zava directly, so the
    /// real graph is the first one a breadth-first walk from the install step meets.
    real_first,
};

const Mode = enum {
    /// gen prints to stdout; the build captures it into the cache (the prototype's wiring).
    capture,
    /// gen writes to a path the build passes as an argument (also in the cache).
    outarg,
    /// captured stdout copied into a WriteFiles directory (also in the cache).
    writefiles,
    /// captured stdout copied into the source tree at generated/api.zig; the module root is that static path.
    source_tree,
};

const Wired = struct { zava: *std.Build.Module, domain: *std.Build.Module };

fn wire(b: *std.Build, maybe_api: ?*std.Build.Module) Wired {
    const t = b.graph.host;
    const zava = b.createModule(.{ .root_source_file = b.path("zava.zig"), .target = t });
    const domain = b.createModule(.{ .root_source_file = b.path("domain.zig"), .target = t });
    zava.addImport("domain", domain);
    domain.addImport("zava", zava);
    if (maybe_api) |api| {
        zava.addImport("api", api);
        domain.addImport("api", api);
        api.addImport("zava", zava);
        api.addImport("domain", domain);
    }
    return .{ .zava = zava, .domain = domain };
}

pub fn build(b: *std.Build) void {
    const t = b.graph.host;

    // Graph 1: the generator, against an empty stub of `api` (or against no `api`).
    const p1 = wire(b, if (graph == .no_stub) null else b.createModule(.{ .root_source_file = b.path("stub_api.zig"), .target = t }));
    const gen_mod = b.createModule(.{ .root_source_file = b.path("gen.zig"), .target = t });
    gen_mod.addImport("zava", p1.zava);
    gen_mod.addImport("domain", p1.domain);
    const gen_run = b.addRunArtifact(b.addExecutable(.{ .name = "gen", .root_module = gen_mod }));

    var source_tree_step: ?*std.Build.Step = null;
    const generated: std.Build.LazyPath = switch (mode) {
        .capture => gen_run.captureStdOut(.{ .basename = "api.zig" }),
        .outarg => gen_run.addOutputFileArg("api.zig"),
        .writefiles => b.addWriteFiles().addCopyFile(gen_run.captureStdOut(.{ .basename = "api.zig" }), "api.zig"),
        .source_tree => blk: {
            const usf = b.addUpdateSourceFiles();
            usf.addCopyFileToSource(gen_run.captureStdOut(.{ .basename = "api.zig" }), "generated/api.zig");
            source_tree_step = &usf.step;
            break :blk b.path("generated/api.zig");
        },
    };

    // Graph 2: the application, against the real generated `api`.
    const api = b.createModule(.{ .root_source_file = generated, .target = t });
    const real = wire(b, api);
    const app_mod = b.createModule(.{ .root_source_file = b.path("app.zig"), .target = t });
    app_mod.addImport("api", api);
    const app = b.addExecutable(.{ .name = "app", .root_module = app_mod });
    if (graph == .real_first) {
        app_mod.addImport("domain", real.domain);
        app_mod.addImport("zava", real.zava);
        b.installArtifact(app);
    }
    if (source_tree_step) |s| app.step.dependOn(s);
    b.step("run", "run the app").dependOn(&b.addRunArtifact(app).step);
    b.getInstallStep().dependOn(&b.addInstallFile(generated, "api.zig").step);

    if (with_check) {
        // Compiles the app without installing it; depends on the generated module.
        const check_mod = b.createModule(.{ .root_source_file = b.path("app.zig"), .target = t });
        check_mod.addImport("api", api);
        const check_exe = b.addExecutable(.{ .name = "app-check", .root_module = check_mod });
        if (source_tree_step) |s| check_exe.step.dependOn(s);
        b.step("check", "compile without installing (what ZLS build-on-save runs)").dependOn(&check_exe.step);
    }
}
