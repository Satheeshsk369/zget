const std = @import("std");
const dns = @import("dns.zig");
const Client = std.http.Client;

fn printProgress(io: std.Io, comptime format: []const u8, args: anytype) void {
    const stderr = std.Io.File.stderr();
    const ls = io.lockStderr(&.{}, null) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, format, args) catch return;
        stderr.writeStreamingAll(io, msg) catch {};
        return;
    };
    defer io.unlockStderr();

    const t = ls.terminal();
    t.writer.print(format, args) catch {};
}

pub const Downloader = struct {
    client: *Client,

    pub const Result = struct {
        status: std.http.Status,
        duration: i128,
        digest: [64]u8,
    };

    pub fn init(client: *Client) Downloader {
        return .{ .client = client };
    }

    pub fn downloadToFile(
        self: *Downloader,
        url: []const u8,
        size: ?u64,
        file: std.Io.File,
        io: std.Io,
    ) !Result {
        const Blake2b512 = std.crypto.hash.blake2.Blake2b512;
        var hasher = Blake2b512.init(.{});
        const start = std.Io.Clock.now(.awake, io).nanoseconds;
        const uri = try std.Uri.parse(url);

        var req = try dns.request(self.client, .GET, uri, .{});
        defer req.deinit();
        try req.sendBodiless();

        var redirect_buf: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        const content_length = response.head.content_length orelse size;
        var transfer_buf: [65536]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const decompress_buf: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .deflate, .gzip => try self.client.allocator.alloc(u8, std.compress.flate.max_window_len),
            .zstd => try self.client.allocator.alloc(u8, std.compress.zstd.default_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        defer self.client.allocator.free(decompress_buf);

        const body = response.readerDecompressing(&transfer_buf, &decompress, decompress_buf);

        var file_buf: [65536]u8 = undefined;
        var writer = file.writer(io, &file_buf);

        var chunk_buf: [65536]u8 = undefined;
        var downloaded: u64 = 0;
        var last_update: i128 = 0;

        while (true) {
            var chunk_writer = std.Io.Writer.fixed(&chunk_buf);
            const n = body.stream(&chunk_writer, std.Io.Limit.limited(chunk_buf.len)) catch |err| switch (err) {
                error.EndOfStream => break,
                else => |e| return e,
            };
            try writer.interface.writeAll(chunk_buf[0..n]);
            hasher.update(chunk_buf[0..n]);
            downloaded += n;
            const now = std.Io.Clock.now(.awake, io).nanoseconds;
            if (now - last_update > 100_000_000) {
                last_update = now;
                if (content_length) |total| {
                    const pct = (@as(f64, @floatFromInt(downloaded)) / @as(f64, @floatFromInt(total))) * 100.0;
                    printProgress(io, "\rDownloading: {d:.1}% ({d} / {d} bytes)", .{ pct, downloaded, total });
                } else {
                    printProgress(io, "\rDownloading: {d} bytes", .{downloaded});
                }
            }
        }
        if (content_length) |total| {
            printProgress(io, "\rDownloading: 100.0% ({d} / {d} bytes)\n", .{ total, total });
        } else {
            printProgress(io, "\rDownloading: {d} bytes\n", .{downloaded});
        }

        try writer.flush();

        var digest: [64]u8 = undefined;
        hasher.final(&digest);

        const stop = std.Io.Clock.now(.awake, io).nanoseconds;
        return .{ .status = response.head.status, .duration = stop - start, .digest = digest };
    }
};
