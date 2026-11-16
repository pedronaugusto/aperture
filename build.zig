const std = @import("std");

/// What a project that depends on aperture builds: the `aperture` module, which imports warp and aegis.
/// Each format is a namespace that lazy analysis drops when a program does not use it.
/// The tests, checks and gate are `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = apertureModule(b, b, target, optimize);
}

fn apertureModule(b: *std.Build, p: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const module = b.addModule("aperture", .{ .root_source_file = p.path("src/aperture.zig"), .target = target, .optimize = optimize });
    addImports(p, module, target, optimize);
    return module;
}

fn addImports(p: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) void {
    module.addImport("aegis", p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis"));
    module.addImport("warp", p.dependency("warp", .{ .target = target, .optimize = optimize }).module("warp"));
}

/// aperture's development: its tests and checks under preflight's gate. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const package = b.dependency("aperture", .{ .target = target, .optimize = optimize });
    const p = package.builder;
    const filters = if (test_filter) |filter| &.{filter} else &.{};
    const root = b.createModule(.{ .root_source_file = p.path("src/tests.zig"), .target = target, .optimize = optimize });
    addImports(p, root, target, optimize);
    // The test doubles and fuzz cases are shakedown's.
    root.addImport("shakedown", b.dependency("shakedown", .{ .target = target, .optimize = optimize }).module("shakedown"));
    const tests = b.addTest(.{ .name = "aperture-tests", .filters = filters, .root_module = root });
    const check = b.step("check", "Compile the tests without running them");
    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    check.dependOn(&tests.step);
    // The README's examples, run as part of the tests.
    const example = b.addExecutable(.{
        .name = "usage",
        .root_module = b.createModule(.{ .root_source_file = p.path("examples/usage.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "aperture", .module = package.module("aperture") }} }),
    });
    const examples = b.step("examples", "Build and run the usage example");
    examples.dependOn(&b.addRunArtifact(example).step);
    test_step.dependOn(examples);
    check.dependOn(&example.step);
    b.getInstallStep().dependOn(&tests.step);
    // The release tier runs the decoders' properties under Zig's fuzzer.
    tools.preflight.addCi(b, p, .{ .tests = test_step, .portable_tests = true, .hardened = .{ .fuzz_step = "test", .tsan_step = "test" } });
    // A plain consumer: aperture, warp and aegis, nothing of aperture's development.
    tools.preflight.addConsumerCheck(b, p, .{ .package = "aperture", .program = p.path("examples/usage.zig"), .packages = &.{ p.dependency("aegis", .{ .target = target, .optimize = optimize }), p.dependency("warp", .{ .target = target, .optimize = optimize }) } });
}
