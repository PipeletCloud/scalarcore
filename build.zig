const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const single_threaded = b.option(bool, "single-threaded", "Enable or disable threading support");

    const libxev = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    });

    const closure = b.dependency("closure", .{
        .target = target,
        .optimize = optimize,
    });

    const module = b.addModule("scalarcore", .{
        .root_source_file = b.path("lib/scalarcore.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
        .imports = &.{
            .{
                .name = "xev",
                .module = libxev.module("xev"),
            },
            .{
                .name = "closure",
                .module = closure.module("closure"),
            },
        },
    });

    const module_tests = b.addTest(.{
        .root_module = module,
    });

    const run_module_tests = b.addRunArtifact(module_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_module_tests.step);
}
