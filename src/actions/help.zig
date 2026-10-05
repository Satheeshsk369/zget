const std = @import("std");
const command = @import("../command.zig");

pub fn run() void {
    std.debug.print(
        \\Usage:
        \\  zigup <command> [arguments]
        \\
        \\Commands:
        \\
    , .{});

    inline for (command.commands) |entry| {
        const alias = comptime blk: {
            if (std.mem.eql(u8, entry.verb, "help")) break :blk "[h]elp";
            if (std.mem.eql(u8, entry.verb, "version")) break :blk "[v]ersion";
            if (std.mem.eql(u8, entry.verb, "env")) break :blk "[e]nv";
            if (std.mem.eql(u8, entry.verb, "update")) break :blk "[up]date";
            if (std.mem.eql(u8, entry.verb, "install")) break :blk "[i]nstall";
            if (std.mem.eql(u8, entry.verb, "delete")) break :blk "[d]elete";
            if (std.mem.eql(u8, entry.verb, "list")) break :blk "[l]ist";
            if (std.mem.eql(u8, entry.verb, "set")) break :blk "[s]et";
            if (std.mem.eql(u8, entry.verb, "current")) break :blk "[c]urrent";
            if (std.mem.eql(u8, entry.verb, "clean")) break :blk "clean";
            if (std.mem.eql(u8, entry.verb, "run")) break :blk "[r]un";
            break :blk entry.verb;
        };
        const usage = if (entry.argLabel) |lbl| alias ++ " " ++ lbl else alias;
        std.debug.print("  {s:<20} {s}\n", .{ usage, entry.description });
        if (std.mem.eql(u8, entry.verb, "install")) {
            std.debug.print("    -mirror=<name>     Select index mirror configured in config.zon\n", .{});
            std.debug.print("    -url=<url>         Specify custom JSON index URL directly\n", .{});
        }
    }
    std.debug.print("\n", .{});
}
