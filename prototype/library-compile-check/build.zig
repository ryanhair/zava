const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "spike",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pg", .module = b.dependency("pg", .{ .target = target, .optimize = optimize }).module("pg") },
                .{ .name = "httpz", .module = b.dependency("httpz", .{ .target = target, .optimize = optimize }).module("httpz") },
            },
        }),
    });
    b.installArtifact(exe);
}
