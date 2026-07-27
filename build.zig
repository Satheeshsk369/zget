const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = blk: {
        const content = @embedFile("build.zig.zon");
        if (std.mem.indexOf(u8, content, ".version")) |idx| {
            if (std.mem.indexOfPos(u8, content, idx, "\"")) |start_idx| {
                if (std.mem.indexOfPos(u8, content, start_idx + 1, "\"")) |end_idx| {
                    break :blk content[start_idx + 1 .. end_idx];
                }
            }
        }
        break :blk "0.0.0";
    };
    const options = b.addOptions();
    options.addOption([]const u8, "version", if (version.len > 0) version else "0.0.0");

    const exe = b.addExecutable(.{
        .name = "zigup",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .imports = &.{
                .{ .name = "options", .module = options.createModule() },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);

    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "options", .module = options.createModule() },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);
}
