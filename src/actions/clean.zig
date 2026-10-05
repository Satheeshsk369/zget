const std = @import("std");
const action = @import("root.zig");

pub fn run(ctx: action.Context) !void {
    const cache_dir = try ctx.cacheDir();
    var dir = std.Io.Dir.openDirAbsolute(ctx.io, cache_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            std.log.info("Cache directory is already clean.", .{});
            return;
        }
        return err;
    };
    defer dir.close(ctx.io);

    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(ctx.io)) |entry| {
        if (entry.kind == .file) {
            dir.deleteFile(ctx.io, entry.name) catch continue;
            count += 1;
        } else if (entry.kind == .directory) {
            dir.deleteTree(ctx.io, entry.name) catch continue;
            count += 1;
        }
    }

    std.log.info("Cleaned {d} items from cache ({s}).", .{ count, cache_dir });
}
