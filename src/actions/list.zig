const std = @import("std");
const Schema = @import("../schema.zig");
const action = @import("root.zig");

fn syncMirror(ctx: action.Context, mirror: []const u8) !void {
    const url = ctx.userConfig.getMirrorUrl(mirror) orelse {
        return error.MirrorNotFound;
    };

    var index = Schema.Index.init(ctx.gpa, ctx.io, ctx.environMap);
    defer index.deinit();

    var httpBuf = std.Io.Writer.Allocating.init(ctx.gpa);
    defer httpBuf.deinit();

    std.log.info("Syncing index from {s} ({s})", .{ mirror, url });
    if ((try index.fetchUrl(url, &httpBuf)) != .ok) {
        std.log.err("failed to fetch index", .{});
        return;
    }

    const cache_path = try ctx.cacheFile(mirror);
    try Schema.Type.saveCache(ctx.gpa, ctx.io, cache_path, httpBuf.written());
}

fn compareInstalledVersions(_: void, a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, "master")) return true;
    if (std.mem.eql(u8, b, "master")) return false;
    const a_ver = std.SemanticVersion.parse(a) catch null;
    const b_ver = std.SemanticVersion.parse(b) catch null;
    if (a_ver != null and b_ver != null) {
        return a_ver.?.order(b_ver.?) == .gt;
    }
    return std.mem.order(u8, a, b) == .gt;
}

pub fn run(ctx: action.Context, mirror_arg: []const u8) !void {
    const stdout = std.Io.File.stdout();
    const mirror = if (mirror_arg.len > 0) mirror_arg else null;
    if (mirror) |m| {
        if (ctx.sync) {
            try syncMirror(ctx, m);
        }

        const cache_path = try ctx.cacheFile(m);
        const schema = Schema.Type.loadCache(ctx.gpa, ctx.io, cache_path) catch |err| {
            std.log.err("failed to load cached index for mirror '{s}': {s}\nUse -S flag (e.g. 'zget -S list {s}') to sync the cache.", .{ m, @errorName(err), m });
            return;
        };
        defer schema.deinit();

        const VersionItem = struct { key: []const u8, date: []const u8 };
        var versions = std.ArrayList(VersionItem).empty;
        defer versions.deinit(ctx.gpa);

        var it = schema.parsed.value.map.iterator();
        while (it.next()) |entry| {
            const date = if (entry.value_ptr.* == .object)
                if (entry.value_ptr.object.get("date")) |d|
                    if (d == .string) d.string else ""
                else
                    ""
            else
                "";
            try versions.append(ctx.gpa, .{ .key = entry.key_ptr.*, .date = date });
        }

        std.mem.sort(VersionItem, versions.items, {}, struct {
            fn lt(_: void, a: VersionItem, b: VersionItem) bool {
                const ord = std.mem.order(u8, a.date, b.date);
                if (ord != .eq) return ord == .gt;
                return std.mem.order(u8, a.key, b.key) == .gt;
            }
        }.lt);

        for (versions.items) |item| {
            const line = try std.fmt.allocPrint(ctx.arena, "{s} ({s})\n", .{ item.key, item.date });
            stdout.writeStreamingAll(ctx.io, line) catch {};
        }
    } else {
        const data_dir = try ctx.dataDir();
        var dir = std.Io.Dir.openDirAbsolute(ctx.io, data_dir, .{ .iterate = true }) catch {
            return;
        };
        defer dir.close(ctx.io);

        const active_ver = action.getActiveVersion(ctx) catch null;
        const builtin = @import("builtin");
        const exe_name = if (comptime builtin.os.tag == .windows) "zig.exe" else "zig";

        var installed = std.ArrayList([]const u8).empty;
        defer installed.deinit(ctx.gpa);

        var it = dir.iterate();
        while (try it.next(ctx.io)) |entry| {
            if (entry.kind == .directory and
                !std.mem.eql(u8, entry.name, "bin") and
                !std.mem.eql(u8, entry.name, "cache") and
                !std.mem.eql(u8, entry.name, "tmp"))
            {
                // Verify exe exists inside folder
                const install_dir = try std.fs.path.join(ctx.arena, &.{ data_dir, entry.name });
                const exe_path = try std.fs.path.join(ctx.arena, &.{ install_dir, exe_name });
                if (std.Io.Dir.openFileAbsolute(ctx.io, exe_path, .{})) |*f| {
                    f.close(ctx.io);
                    try installed.append(ctx.gpa, try ctx.arena.dupe(u8, entry.name));
                } else |_| {}
            }
        }

        if (installed.items.len == 0) {
            std.log.info("No installed versions found in {s}", .{data_dir});
            return;
        }

        std.mem.sort([]const u8, installed.items, {}, compareInstalledVersions);

        for (installed.items) |ver| {
            const is_active = if (active_ver) |act| std.mem.eql(u8, act, ver) else false;
            const line = if (is_active)
                try std.fmt.allocPrint(ctx.arena, "* {s} (default)\n", .{ver})
            else
                try std.fmt.allocPrint(ctx.arena, "  {s}\n", .{ver});
            stdout.writeStreamingAll(ctx.io, line) catch {};
        }
    }
}
