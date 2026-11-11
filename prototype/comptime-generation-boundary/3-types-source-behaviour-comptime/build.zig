const std = @import("std");
fn wire(b: *std.Build, api: *std.Build.Module) struct { zava: *std.Build.Module, domain: *std.Build.Module } {
    const t = b.graph.host;
    const zava = b.createModule(.{ .root_source_file = b.path("zava.zig"), .target = t });
    const domain = b.createModule(.{ .root_source_file = b.path("domain.zig"), .target = t });
    zava.addImport("api", api);
    domain.addImport("api", api);
    domain.addImport("zava", zava);
    api.addImport("zava", zava);
    api.addImport("domain", domain);
    return .{ .zava = zava, .domain = domain };
}
pub fn build(b: *std.Build) void {
    const t = b.graph.host;
    const p1 = wire(b, b.createModule(.{ .root_source_file = b.path("stub_api.zig"), .target = t }));
    const gen_mod = b.createModule(.{ .root_source_file = b.path("gen.zig"), .target = t });
    gen_mod.addImport("zava", p1.zava);
    gen_mod.addImport("domain", p1.domain);
    const generated = b.addRunArtifact(b.addExecutable(.{ .name = "gen", .root_module = gen_mod })).captureStdOut(.{ .basename = "api.zig" });
    const api = b.createModule(.{ .root_source_file = generated, .target = t });
    _ = wire(b, api);
    const app_mod = b.createModule(.{ .root_source_file = b.path("app.zig"), .target = t });
    app_mod.addImport("api", api);
    b.step("run", "run").dependOn(&b.addRunArtifact(b.addExecutable(.{ .name = "app", .root_module = app_mod })).step);
    b.getInstallStep().dependOn(&b.addInstallFile(generated, "api.zig").step);
}
