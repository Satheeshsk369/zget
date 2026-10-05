const std = @import("std");
const action = @import("root.zig");

pub fn getActiveVersion(ctx: action.Context) !?[]const u8 {
    const binDir = try ctx.binDir();
    const builtin = @import("builtin");
    const exe_name = if (comptime builtin.os.tag == .windows) "zig.exe" else "zig";
    const exe_path = try std.fs.path.join(ctx.arena, &.{ binDir, exe_name });

    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.readLinkAbsolute(ctx.io, exe_path, &link_buf) catch return null;
    const target = link_buf[0..len];

    // target is typically <dataDir>/<ver>/zig or ../share/zig/<ver>/zig
    if (std.fs.path.dirname(target)) |dir| {
        const ver = std.fs.path.basename(dir);
        if (ver.len > 0 and !std.mem.eql(u8, ver, ".") and !std.mem.eql(u8, ver, "/")) {
            return try ctx.arena.dupe(u8, ver);
        }
    }
    return null;
}

pub fn run(ctx: action.Context) !void {
    const stdout = std.Io.File.stdout();
    if (try getActiveVersion(ctx)) |ver| {
        const installDir = try ctx.versionDir(ver);
        const builtin = @import("builtin");
        const exe_name = if (comptime builtin.os.tag == .windows) "zig.exe" else "zig";
        const exe_path = try std.fs.path.join(ctx.arena, &.{ installDir, exe_name });
        const line = try std.fmt.allocPrint(ctx.arena, "{s} ({s})\n", .{ ver, exe_path });
        stdout.writeStreamingAll(ctx.io, line) catch {};
    } else {
        stdout.writeStreamingAll(ctx.io, "none\n") catch {};
    }
}
