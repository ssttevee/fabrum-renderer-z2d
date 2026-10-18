const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const z2d = b.dependency("z2d", .{ .target = target, .optimize = optimize }).module("z2d");

    // The renderer. It imports `fabrum`, which the app gives it, so that the
    // renderer and the app share one fabrum whatever options the app passes:
    //
    //     renderer_module.addImport("fabrum", fabrum_module);
    const mod = b.addModule("fabrum-renderer-z2d", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "z2d", .module = z2d }},
    });

    const test_step = b.step("test", "Run tests");

    // This package's own tests bring their own fabrum, lazily, so that apps
    // depending on the renderer never fetch or build it.
    if (!b.isRoot()) return;
    const fabrum_dep = b.lazyDependency("fabrum", .{
        .target = target,
        .optimize = optimize,
        .platform = .none,
    }) orelse return;
    mod.addImport("fabrum", fabrum_dep.module("fabrum"));

    const unit_tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    const render_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/render_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fabrum", .module = fabrum_dep.module("fabrum") },
            .{ .name = "fabrum-renderer-z2d", .module = mod },
        },
    }) });
    test_step.dependOn(&b.addRunArtifact(render_tests).step);
}
