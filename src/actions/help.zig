const std = @import("std");
const command = @import("../command.zig");

pub fn run() void {
    std.debug.print(
        \\Usage:
        \\  zget <command> [arguments]
        \\
        \\Manage Zig versions:
        \\
    , .{});

    inline for (command.commands) |entry| {
        if (comptime std.mem.eql(u8, entry.verb, "update")) {
            std.debug.print("\nMaintain zget:\n", .{});
        }

        const call = comptime blk: {
            var prefix: []const u8 = entry.verb;
            if (entry.alias) |al| {
                prefix = prefix ++ ", " ++ al;
            }
            if (entry.argLabel) |arg| {
                prefix = prefix ++ " " ++ arg;
            }
            break :blk prefix;
        };

        std.debug.print("  {s:<25} {s}\n", .{ call, entry.description });

        if (comptime std.mem.eql(u8, entry.verb, "install")) {
            std.debug.print("    --set                     Set this version as default\n", .{});
            std.debug.print("    --mirror=<name>           Use a mirror from config.zon\n", .{});
            std.debug.print("    --url=<url>               Use a direct index URL\n", .{});
        }
    }
    std.debug.print("\n", .{});
}
