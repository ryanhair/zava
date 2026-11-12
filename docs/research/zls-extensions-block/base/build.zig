//! PROTOTYPE, throwaway. In the real thing the kernel's build helper does all of this from one call.
const std = @import("std");

// ADDED for the measurement (not in the prototype). The driver rewrites this line.
// false is the prototype as it stands: no `check` step.
const with_check = true;

const Mods = struct { zava: *std.Build.Module, domain: *std.Build.Module, postgres: *std.Build.Module };

/// The domain, the kernel and the extensions, optionally with generated source.
fn wire(b: *std.Build, api: ?*std.Build.Module) Mods {
    const t = b.graph.host;
    const m: Mods = .{
        .zava = b.createModule(.{ .root_source_file = b.path("zava.zig"), .target = t }),
        .domain = b.createModule(.{ .root_source_file = b.path("domain.zig"), .target = t }),
        .postgres = b.createModule(.{ .root_source_file = b.path("postgres.zig"), .target = t }),
    };
    m.zava.addImport("domain", m.domain);
    m.domain.addImport("zava", m.zava);
    m.domain.addImport("postgres", m.postgres);
    m.postgres.addImport("zava", m.zava);
    if (api) |a| {
        m.zava.addImport("api", a);
        m.domain.addImport("api", a);
        a.addImport("zava", m.zava);
        a.addImport("domain", m.domain);
        a.addImport("postgres", m.postgres);
    }
    return m;
}

fn tool(b: *std.Build, name: []const u8, m: Mods) *std.Build.Step.Compile {
    const mod = b.createModule(.{ .root_source_file = b.path(b.fmt("{s}.zig", .{name})), .target = b.graph.host });
    mod.addImport("zava", m.zava);
    return b.addExecutable(.{ .name = name, .root_module = mod });
}

pub fn build(b: *std.Build) void {
    // Phase 1: the domain without generated source. Emitter and command runner are built from it.
    const bare = wire(b, null);
    const generated = b.addRunArtifact(tool(b, "gen", bare)).captureStdOut(.{ .basename = "api.zig" });

    // Phase 2: the program, against generated source.
    const api = b.createModule(.{ .root_source_file = generated, .target = b.graph.host });
    const full = wire(b, api);
    const app = b.createModule(.{ .root_source_file = b.path("app.zig"), .target = b.graph.host });
    app.addImport("api", api);
    app.addImport("zava", full.zava);
    app.addImport("postgres", full.postgres);
    const exe = b.addExecutable(.{ .name = "app", .root_module = app });
    b.step("run", "run the app").dependOn(&b.addRunArtifact(exe).step);
    if (with_check) b.step("check", "compile the app (and so the generator and the declaration); install nothing").dependOn(&exe.step);
    b.getInstallStep().dependOn(&b.addInstallFile(generated, "api.zig").step);

    // Build-run code: `zig build zava -- postgres.migrate migrations`
    const cmd = b.addRunArtifact(tool(b, "runner", bare));
    cmd.setCwd(b.path("."));
    cmd.addPassthruArgs();
    b.step("zava", "run an extension command (no arguments: list them)").dependOn(&cmd.step);
}
