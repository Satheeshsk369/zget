const std = @import("std");
const action = @import("actions/root.zig");
const config = @import("config.zig");

pub fn main(init: std.process.Init) void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    var args = init.minimal.args.iterateAllocator(arena) catch {
        std.log.err("Failed to initialize process arguments.", .{});
        std.process.exit(1);
    };

    var sync = false;
    var list = std.ArrayList([:0]const u8).empty;

    if (args.next()) |first| {
        list.append(arena, first) catch {
            std.log.err("Out of memory.", .{});
            std.process.exit(1);
        };
    }
    if (args.next()) |second| {
        if (std.mem.eql(u8, second, "-S")) {
            sync = true;
        } else {
            list.append(arena, second) catch {
                std.log.err("Out of memory.", .{});
                std.process.exit(1);
            };
        }
    }

    while (args.next()) |rest| {
        list.append(arena, rest) catch {
            std.log.err("Out of memory.", .{});
            std.process.exit(1);
        };
    }
    const argslist = list.items;

    const config_zon_path = action.configPath(arena, init.environ_map) catch |err| {
        switch (err) {
            error.HomeNotFound, error.EnvironmentVariableNotFound => {
                std.log.err("Failed to determine config path: missing HOME, USERPROFILE, or APPDATA environment variables.", .{});
            },
            else => {
                std.log.err("Failed to determine config path: {s}.", .{@errorName(err)});
            },
        }
        std.process.exit(1);
    };

    const config_val = config.Config.loadOrInit(arena, init.io, config_zon_path) catch |err| {
        std.log.err("Failed to load or initialize config file at '{s}': {s}.", .{ config_zon_path, @errorName(err) });
        std.process.exit(1);
    };

    const ctx = action.Context{
        .gpa = gpa,
        .arena = arena,
        .io = init.io,
        .environMap = init.environ_map,
        .pathEnv = init.environ_map.get("PATH") orelse "",
        .userConfig = config_val,
        .args = argslist,
        .sync = sync,
    };

    const cmd = action.parseCommand(argslist) orelse {
        if (argslist.len < 2) {
            std.log.err("No command provided.\nUse 'zget help' for usage details.", .{});
        } else {
            std.log.err("Unknown command: {s}.\nUse 'zget help' for usage details.", .{argslist[1]});
        }
        std.process.exit(1);
    };

    action.run(cmd, ctx) catch |err| {
        switch (err) {
            error.AccessDenied => {
                std.log.err("Permission denied: ensure you have write permissions to the installation path and default symlink directory.", .{});
            },
            error.HomeNotFound, error.EnvironmentVariableNotFound => {
                std.log.err("Required environment variables (HOME, USERPROFILE, or PATH) are missing.", .{});
            },
            error.MirrorNotFound => {
                std.log.err("The requested mirror is not defined in config.zon.", .{});
            },
            error.SignatureVerificationFailed,
            error.MinisignFilenameMismatch,
            error.InvalidMinisignFormat,
            error.UnsupportedMinisignAlgorithm,
            => {
                std.log.err("Signature verification failed: {s}.", .{@errorName(err)});
            },
            else => {
                std.log.err("Command failed with error: {s}.", .{@errorName(err)});
            },
        }
        std.process.exit(1);
    };
}

test {
    std.testing.refAllDecls(@This());
}
