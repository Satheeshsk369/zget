const std = @import("std");
const action = @import("root.zig");
const current = @import("current.zig");

pub fn run(ctx: action.Context, ver: []const u8) !void {
    const installDir = try ctx.versionDir(ver);
    if (!action.dirExists(ctx, installDir)) return error.FileNotFound;

    // Check if the version being deleted is currently active
    if (current.getActiveVersion(ctx) catch null) |active| {
        if (std.mem.eql(u8, active, ver)) {
            const binDir = try ctx.binDir();
            var bd = std.Io.Dir.openDirAbsolute(ctx.io, binDir, .{}) catch null;
            if (bd) |*d| {
                defer d.close(ctx.io);
                const builtin = @import("builtin");
                const exe_name = if (comptime builtin.os.tag == .windows) "zig.exe" else "zig";
                d.deleteFile(ctx.io, exe_name) catch {};
            }
            std.log.warn("Version {s} was the active default; default link removed.", .{ver});
        }
    }

    const data_dir = try ctx.dataDir();
    var zd = try std.Io.Dir.openDirAbsolute(ctx.io, data_dir, .{});
    defer zd.close(ctx.io);

    try zd.deleteTree(ctx.io, ver);

    std.log.info("Successfully deleted {s}.", .{ver});
}
