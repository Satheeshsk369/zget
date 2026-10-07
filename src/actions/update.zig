const std = @import("std");
const dl = @import("../download.zig");
const action = @import("root.zig");
const dns = @import("../dns.zig");

pub fn run(ctx: action.Context, requested_tag: []const u8) !void {
    const builtin = @import("builtin");
    const suffix = if (builtin.os.tag == .windows) ".exe" else "";
    const expected_asset_name = try std.fmt.allocPrint(ctx.arena, "zget-{s}{s}", .{ action.targetKey(), suffix });

    var client = std.http.Client{ .allocator = ctx.gpa, .io = ctx.io };
    client.initDefaultProxies(ctx.gpa, ctx.environMap) catch {};
    defer client.deinit();
    const extra_headers = &[_]std.http.Header{
        .{ .name = "User-Agent", .value = "zget-client" },
    };

    var httpBuf = std.Io.Writer.Allocating.init(ctx.gpa);
    defer httpBuf.deinit();

    const uri = try std.Uri.parse("https://api.github.com/repos/Satheeshsk369/zget/releases");
    std.log.info("Checking for updates from GitHub", .{});
    const status = try dns.fetch(&client, uri, extra_headers, &httpBuf.writer);

    if (status != .ok) {
        std.log.err("failed to check for updates: HTTP {s}", .{@tagName(status)});
        return error.HttpError;
    }

    const GitHubRelease = struct {
        tag_name: []const u8,
        assets: []const struct {
            name: []const u8,
            browser_download_url: []const u8,
        },
    };

    const releases_parsed = std.json.parseFromSlice(
        []GitHubRelease,
        ctx.arena,
        httpBuf.written(),
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        std.log.err("failed to parse release metadata: {s}", .{@errorName(err)});
        return;
    };
    defer releases_parsed.deinit();

    const releases = releases_parsed.value;
    if (releases.len == 0) {
        std.log.info("No releases found.", .{});
        return;
    }

    const current_ver = @import("options").version;
    var clean_current: []const u8 = current_ver;
    if (std.mem.startsWith(u8, clean_current, "v")) {
        clean_current = clean_current[1..];
    }

    var target_release: ?GitHubRelease = null;
    var download_url: ?[]const u8 = null;

    if (requested_tag.len > 0) {
        var clean_req: []const u8 = requested_tag;
        if (std.mem.startsWith(u8, clean_req, "v")) clean_req = clean_req[1..];

        if (std.mem.eql(u8, clean_req, clean_current)) {
            std.log.info("zget is already at version {s}.", .{current_ver});
            return;
        }

        for (releases) |rel| {
            var rel_tag: []const u8 = rel.tag_name;
            if (std.mem.startsWith(u8, rel_tag, "v")) rel_tag = rel_tag[1..];
            if (std.mem.eql(u8, rel_tag, clean_req)) {
                for (rel.assets) |asset| {
                    if (std.mem.eql(u8, asset.name, expected_asset_name)) {
                        target_release = rel;
                        download_url = asset.browser_download_url;
                        break;
                    }
                }
                if (target_release != null) break;
            }
        }

        if (target_release == null) {
            std.log.err("release '{s}' with binary '{s}' not found.", .{ requested_tag, expected_asset_name });
            return error.FileNotFound;
        }
    } else {
        // Find the latest release that actually has the asset matching expected_asset_name
        for (releases) |rel| {
            for (rel.assets) |asset| {
                if (std.mem.eql(u8, asset.name, expected_asset_name)) {
                    target_release = rel;
                    download_url = asset.browser_download_url;
                    break;
                }
            }
            if (target_release != null) break;
        }

        const release = target_release orelse {
            std.log.err("no compatible binary asset found for {s} in any release", .{expected_asset_name});
            return error.HttpError;
        };
        var clean_release: []const u8 = release.tag_name;
        if (std.mem.startsWith(u8, clean_release, "v")) {
            clean_release = clean_release[1..];
        }

        if (std.mem.eql(u8, clean_release, clean_current)) {
            std.log.info("zget is already up to date ({s}).", .{current_ver});
            return;
        }

        const parsed_current = std.SemanticVersion.parse(clean_current) catch null;
        const parsed_release = std.SemanticVersion.parse(clean_release) catch null;

        if (parsed_release != null and parsed_current != null) {
            if (parsed_release.?.order(parsed_current.?) != .gt) {
                std.log.info("zget is already up to date ({s}).", .{current_ver});
                return;
            }
        }
    }

    const url = download_url.?;

    const bin_dir = try ctx.binDir();
    const exe_name = if (comptime builtin.os.tag == .windows) "zget.exe" else "zget";
    const tmp_name = if (comptime builtin.os.tag == .windows) "zget.tmp.exe" else "zget.tmp";
    const temp_exe_path = try std.fs.path.join(ctx.arena, &.{ bin_dir, tmp_name });

    std.log.info("Downloading new binary from {s}", .{url});

    var dl_client = std.http.Client{ .allocator = ctx.gpa, .io = ctx.io };
    dl_client.initDefaultProxies(ctx.gpa, ctx.environMap) catch {};
    defer dl_client.deinit();
    var downloader = dl.Downloader.init(&dl_client);

    var file = try std.Io.Dir.createFileAbsolute(ctx.io, temp_exe_path, .{});
    var success = false;
    defer {
        file.close(ctx.io);
        if (!success) {
            std.Io.Dir.deleteFile(std.Io.Dir.cwd(), ctx.io, temp_exe_path) catch {};
        }
    }

    const dlResult = try dl.Downloader.downloadToFile(&downloader, url, null, file, ctx.io);
    if (dlResult.status != .ok) {
        std.log.err("failed to download update: HTTP {s}", .{@tagName(dlResult.status)});
        return error.HttpError;
    }
    const dl_secs = @as(f64, @floatFromInt(dlResult.duration)) / 1_000_000_000.0;

    if (comptime builtin.os.tag != .windows) {
        const fd = file.handle;
        const rc = std.posix.system.fchmod(fd, 0o755);
        if (rc != 0) {
            std.log.err("failed to set executable permission: rc {d}", .{rc});
            return error.AccessDenied;
        }
    }

    var bd = try std.Io.Dir.openDirAbsolute(ctx.io, bin_dir, .{});
    defer bd.close(ctx.io);

    bd.deleteFile(ctx.io, exe_name) catch {};
    success = true;
    bd.rename(tmp_name, bd, exe_name, ctx.io) catch |err| {
        std.log.err("failed to replace zget binary: {s}", .{@errorName(err)});
        return err;
    };

    std.log.info("Successfully updated zget in {d:.2}s.", .{dl_secs});
}
