const std = @import("std");

pub const Command = union(enum) {
    help,
    version,
    env,
    current,
    clean,
    install: []const u8,
    delete: []const u8,
    list: []const u8,
    set: []const u8,
    run: []const u8,
    update: []const u8,
};

pub const Entry = struct {
    verb: []const u8,
    argLabel: ?[]const u8,
    description: []const u8,
};

pub const commands: []const Entry = &.{
    .{ .verb = "help", .argLabel = null, .description = "Print this message" },
    .{ .verb = "version", .argLabel = null, .description = "Print zigup tool version" },
    .{ .verb = "env", .argLabel = null, .description = "Print configuration and environment paths" },
    .{ .verb = "current", .argLabel = null, .description = "Show currently active Zig version and path" },
    .{ .verb = "clean", .argLabel = null, .description = "Clean cached indexes and temporary downloads" },
    .{ .verb = "install", .argLabel = "<TAG>", .description = "Download and install a version (--set to activate)" },
    .{ .verb = "delete", .argLabel = "<TAG>", .description = "Delete an installed version" },
    .{ .verb = "list", .argLabel = "<MIRROR>", .description = "List local installs (or remote versions if mirror is specified)" },
    .{ .verb = "set", .argLabel = "<TAG>", .description = "Set an installed version as the default" },
    .{ .verb = "run", .argLabel = "<TAG> [ARGS...]", .description = "Run a specific installed Zig version" },
    .{ .verb = "update", .argLabel = "[TAG]", .description = "Update zigup tool (optionally to a specific version)" },
};
