const std = @import("std");
const action = @import("root.zig");

pub fn run(ctx: action.Context, ver: []const u8) !void {
    const installDir = try ctx.versionDir(ver);
    const builtin = @import("builtin");
    const exe_name = if (comptime builtin.os.tag == .windows) "zig.exe" else "zig";
    const exe_path = try std.fs.path.join(ctx.arena, &.{ installDir, exe_name });

    if (std.Io.Dir.openFileAbsolute(ctx.io, exe_path, .{})) |*f| {
        f.close(ctx.io);
    } else |_| {
        std.log.err("Version {s} is not installed. Run 'zigup install {s}' first.", .{ ver, ver });
        return error.FileNotFound;
    }

    var argv = std.ArrayList([]const u8).empty;
    try argv.append(ctx.arena, exe_path);

    var found_ver = false;
    for (ctx.args) |arg| {
        if (!found_ver) {
            if (std.mem.eql(u8, arg, ver)) {
                found_ver = true;
            }
        } else {
            try argv.append(ctx.arena, arg);
        }
    }

    var child = try std.process.spawn(ctx.io, .{
        .argv = argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });

    const term = try child.wait(ctx.io);
    switch (term) {
        .exited => |code| {
            if (code != 0) std.process.exit(code);
        },
        .signal => |sig| {
            std.process.exit(128 + @as(u8, @truncate(@intFromEnum(sig))));
        },
        else => std.process.exit(1),
    }
}
