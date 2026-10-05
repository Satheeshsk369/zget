const std = @import("std");
const Schema = @import("../schema.zig");
const dl = @import("../download.zig");
const action = @import("root.zig");
const minisign = @import("../minisign.zig");

const zig_pubkey = "RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U";

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

pub fn run(ctx: action.Context, ver: []const u8) !void {
    var mirror_opt: ?[]const u8 = null;
    var url_opt: ?[]const u8 = null;

    for (ctx.args) |arg| {
        if (std.mem.startsWith(u8, arg, "-mirror=")) {
            mirror_opt = arg["-mirror=".len..];
        } else if (std.mem.startsWith(u8, arg, "-url=")) {
            url_opt = arg["-url=".len..];
        }
    }

    if (mirror_opt != null and url_opt != null) {
        std.log.err("cannot specify both -mirror and -url", .{});
        return;
    }

    const mirror_name = mirror_opt orelse ctx.userConfig.defaultMirror;
    if (ctx.userConfig.getMirrorUrl(mirror_name) == null) {
        return error.MirrorNotFound;
    }

    if (ctx.sync and url_opt == null) {
        try syncMirror(ctx, mirror_name);
    }
    var index = Schema.Index.init(ctx.gpa, ctx.io, ctx.environMap);
    defer index.deinit();
    var schema = blk: {
        if (url_opt) |u| {
            var httpBuf = std.Io.Writer.Allocating.init(ctx.gpa);
            defer httpBuf.deinit();
            std.log.info("Fetching index from {s}", .{u});
            if ((try index.fetchUrl(u, &httpBuf)) != .ok) {
                std.log.err("failed to fetch index", .{});
                return error.HttpError;
            }
            break :blk try Schema.Type.parse(ctx.gpa, httpBuf.written());
        } else {
            if (ctx.userConfig.getMirrorUrl(mirror_name) == null) {
                return error.MirrorNotFound;
            }
            const cache_path = try ctx.cacheFile(mirror_name);
            break :blk Schema.Type.loadCache(ctx.gpa, ctx.io, cache_path) catch |err| {
                if (ctx.userConfig.getMirrorUrl(mirror_name)) |url| {
                    var httpBuf = std.Io.Writer.Allocating.init(ctx.gpa);
                    defer httpBuf.deinit();
                    std.log.warn("Cache not found for '{s}'. Fetching from {s}", .{ mirror_name, url });
                    if ((try index.fetchUrl(url, &httpBuf)) == .ok) {
                        try Schema.Type.saveCache(ctx.gpa, ctx.io, cache_path, httpBuf.written());
                        break :blk try Schema.Type.parse(ctx.gpa, httpBuf.written());
                    }
                }
                std.log.err("failed to load cached index for mirror '{s}': {s}\nUse -S flag (e.g. 'zigup -S install {s}') to sync the cache.", .{ mirror_name, @errorName(err), ver });
                return error.FileNotFound;
            };
        }
    };
    defer schema.deinit();
    const platform = Schema.Platform.parse(action.targetKey()) orelse {
        std.log.err("unsupported platform: {s}", .{action.targetKey()});
        return;
    };

    const src = schema.get(ver, platform) orelse {
        std.log.err("no binary found for version {s} on {s}", .{ ver, action.targetKey() });
        return;
    };

    try runFromSource(ctx, ver, src);
}

/// Download (if needed), extract, and activate a specific source entry.
/// Called by both `install` and `use`.
pub fn runFromSource(ctx: action.Context, ver: []const u8, src: Schema.Source) !void {
    const dataDir = try ctx.dataDir();
    const binDir = try ctx.binDir();
    const installDir = try ctx.versionDir(ver);

    try action.ensureDir(ctx.io, dataDir);
    try action.ensureDir(ctx.io, binDir);

    const builtin = @import("builtin");
    const zig_exe_name = if (comptime builtin.os.tag == .windows) "zig.exe" else "zig";
    const installed_exe = try std.fs.path.join(ctx.arena, &.{ installDir, zig_exe_name });
    const is_installed = if (std.Io.Dir.openFileAbsolute(ctx.io, installed_exe, .{})) |*f| b: {
        f.close(ctx.io);
        break :b true;
    } else |_| false;

    if (is_installed) {
        if (!ctx.sync) {
            std.log.info("Version {s} is already installed.", .{ver});
            return;
        }
        std.log.info("Re-installing version {s} due to sync flag...", .{ver});
        const data_dir = try ctx.dataDir();
        var zd = try std.Io.Dir.openDirAbsolute(ctx.io, data_dir, .{});
        defer zd.close(ctx.io);
        zd.deleteTree(ctx.io, ver) catch {};
    } else if (action.dirExists(ctx, installDir)) {
        const data_dir = try ctx.dataDir();
        var zd = try std.Io.Dir.openDirAbsolute(ctx.io, data_dir, .{});
        defer zd.close(ctx.io);
        zd.deleteTree(ctx.io, ver) catch {};
    }

    {
        var idx = Schema.Index.init(ctx.gpa, ctx.io, ctx.environMap);
        defer idx.deinit();

        var dl_client = std.http.Client{ .allocator = ctx.gpa, .io = ctx.io };
        dl_client.initDefaultProxies(ctx.gpa, ctx.environMap) catch {};
        defer dl_client.deinit();
        var downloader = dl.Downloader.init(&dl_client);
        var split = std.mem.splitBackwardsAny(u8, src.tarball, "/");
        const filename = split.first();

        std.log.info("Downloading {s}", .{ver});

        const minisig_url = try std.fmt.allocPrint(ctx.arena, "{s}.minisig", .{src.tarball});
        var minisig_buf = std.Io.Writer.Allocating.init(ctx.gpa);
        defer minisig_buf.deinit();
        if ((try idx.fetchUrl(minisig_url, &minisig_buf)) != .ok) {
            std.log.err("failed to fetch .minisig for {s}", .{filename});
            return;
        }

        const cache_dir = try ctx.cacheDir();
        try action.ensureDir(ctx.io, cache_dir);
        const download_path = try std.fs.path.join(ctx.arena, &.{ cache_dir, filename });
        defer std.Io.Dir.deleteFile(std.Io.Dir.cwd(), ctx.io, download_path) catch {};

        var file = try std.Io.Dir.createFileAbsolute(ctx.io, download_path, .{});
        defer file.close(ctx.io);

        const dlResult = dl.Downloader.downloadToFile(&downloader, src.tarball, src.size, file, ctx.io) catch |err| {
            std.log.err("failed to download tarball: {s}", .{@errorName(err)});
            return;
        };
        if (dlResult.status != .ok) {
            std.log.err("failed to download tarball. HTTP {s}", .{@tagName(dlResult.status)});
            return;
        }
        const dl_secs = @as(f64, @floatFromInt(dlResult.duration)) / 1_000_000_000.0;

        minisign.verifyMinisign(minisig_buf.written(), &dlResult.digest, filename, zig_pubkey) catch |err| {
            std.log.err("Minisign verification failed: {s}", .{@errorName(err)});
            return;
        };
        std.log.info("Minisign OK.", .{});
        try action.ensureDir(ctx.io, installDir);
        const is_zip = std.mem.endsWith(u8, filename, ".zip");

        var archive_file = try std.Io.Dir.openFileAbsolute(ctx.io, download_path, .{});
        defer archive_file.close(ctx.io);

        var dest_dir = try std.Io.Dir.openDirAbsolute(ctx.io, installDir, .{});
        defer dest_dir.close(ctx.io);

        var f_buf: [65536]u8 = undefined;
        var file_reader = archive_file.reader(ctx.io, &f_buf);
        if (is_zip) {
            std.log.info("Extracting archive to {s}", .{installDir});
            try action.extractZipStrip(ctx.io, dest_dir, &file_reader);
        } else {
            const decompress_buf = try ctx.gpa.alloc(u8, 65536);
            var xz_stream = try std.compress.xz.Decompress.init(&file_reader.interface, ctx.gpa, decompress_buf);
            defer xz_stream.deinit();
            try std.tar.extract(ctx.io, dest_dir, &xz_stream.reader, .{
                .strip_components = 1,
            });
        }

        std.log.info("Successfully installed {s} in {d:.2}s.", .{ ver, dl_secs });

        var should_set = false;
        for (ctx.args) |arg| {
            if (std.mem.eql(u8, arg, "--set") or std.mem.eql(u8, arg, "-s")) {
                should_set = true;
                break;
            }
        }
        if (should_set) {
            try @import("set.zig").run(ctx, ver);
        }
    }
}
