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
    alias: ?[]const u8,
    description: []const u8,
};

pub const commands: []const Entry = &.{
    .{ .verb = "install", .argLabel = "<TAG>", .alias = "i", .description = "Install a Zig version" },
    .{ .verb = "set", .argLabel = "<TAG>", .alias = "s", .description = "Set the default version" },
    .{ .verb = "list", .argLabel = "[MIRROR]", .alias = "l", .description = "List local or remote versions" },
    .{ .verb = "current", .argLabel = null, .alias = "c", .description = "Show the active version" },
    .{ .verb = "run", .argLabel = "<TAG> [ARGS...]", .alias = "r", .description = "Run a version with arguments" },
    .{ .verb = "delete", .argLabel = "<TAG>", .alias = "d", .description = "Delete an installed version" },
    .{ .verb = "update", .argLabel = "[TAG]", .alias = "up", .description = "Update the zget binary" },
    .{ .verb = "clean", .argLabel = null, .alias = "cl", .description = "Delete cache and downloads" },
    .{ .verb = "env", .argLabel = null, .alias = "e", .description = "Print paths and environment" },
    .{ .verb = "version", .argLabel = null, .alias = "v", .description = "Print the zget version" },
    .{ .verb = "help", .argLabel = null, .alias = "h", .description = "Print this message" },
};
