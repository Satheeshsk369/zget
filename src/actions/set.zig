const std = @import("std");
const action = @import("root.zig");

pub fn run(ctx: action.Context, ver: []const u8) !void {
    const binDir = try ctx.binDir();
    const installDir = try ctx.versionDir(ver);

    if (!action.dirExists(ctx, installDir)) {
        std.log.err("Version {s} is not installed. Please run 'zigup install {s}' first.", .{ ver, ver });
        return error.FileNotFound;
    }

    try action.ensureDir(ctx.io, binDir);

    const builtin = @import("builtin");
    if (comptime builtin.os.tag == .windows) {
        const src_exe = try std.fs.path.join(ctx.arena, &.{ installDir, "zig.exe" });
        const dst_exe = try std.fs.path.join(ctx.arena, &.{ binDir, "zig.exe" });
        var src_file = try std.Io.Dir.openFileAbsolute(ctx.io, src_exe, .{});
        defer src_file.close(ctx.io);
        var dst_file = try std.Io.Dir.createFileAbsolute(ctx.io, dst_exe, .{});
        defer dst_file.close(ctx.io);
        var f_buf: [65536]u8 = undefined;
        var r = src_file.reader(ctx.io, &f_buf);
        var w = dst_file.writer(ctx.io, &f_buf);
        var chunk: [65536]u8 = undefined;
        while (true) {
            const n = try r.interface.readSliceShort(&chunk);
            if (n == 0) break;
            try w.interface.writeAll(chunk[0..n]);
        }
        try w.flush();
    } else {
        const targetExe = try std.fs.path.join(ctx.arena, &.{ installDir, "zig" });
        const targetRel = std.fs.path.relativeAlloc(ctx.arena, binDir, ctx.environMap, binDir, targetExe) catch targetExe;

        var bd = try std.Io.Dir.openDirAbsolute(ctx.io, binDir, .{});
        defer bd.close(ctx.io);
        bd.deleteFile(ctx.io, "zig") catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        try bd.symLink(ctx.io, targetRel, "zig", .{});
    }
    std.log.info("Set {s} as default.", .{ver});
}
