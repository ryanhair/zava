const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.graph.host;
    // Generator: domain sees an EMPTY stub for "api".
    const stub = b.createModule(.{ .root_source_file = b.path("stub_api.zig"), .target = target });
    const gen_domain = b.createModule(.{ .root_source_file = b.path("domain.zig"), .target = target });
    gen_domain.addImport("api", stub);
    const gen_mod = b.createModule(.{ .root_source_file = b.path("gen.zig"), .target = target });
    gen_mod.addImport("domain", gen_domain);
    const gen = b.addExecutable(.{ .name = "gen", .root_module = gen_mod });
    const generated = b.addRunArtifact(gen).captureStdOut(.{ .basename = "api.zig" });
    // App: domain and generated api import each other.
    const domain = b.createModule(.{ .root_source_file = b.path("domain.zig"), .target = target });
    const api = b.createModule(.{ .root_source_file = generated, .target = target });
    domain.addImport("api", api);
    api.addImport("domain", domain);
    const app_mod = b.createModule(.{ .root_source_file = b.path("app.zig"), .target = target });
    app_mod.addImport("api", api);
    const app = b.addExecutable(.{ .name = "app", .root_module = app_mod });
    b.step("run", "run").dependOn(&b.addRunArtifact(app).step);
    const install = b.addInstallFile(generated, "api.zig");
    b.getInstallStep().dependOn(&install.step);
}
