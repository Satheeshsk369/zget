const std = @import("std");

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

fn readXZUncompressedSize(io: std.Io, file: std.Io.File, file_size: u64) !?u64 {
    if (file_size < 32) return null;
    var footer_buf: [12]u8 = undefined;
    var f_buf: [1024]u8 = undefined;
    var r = file.reader(io, &f_buf);

    try r.seekTo(file_size - 12);
    try r.interface.readSliceAll(&footer_buf);
    if (!std.mem.eql(u8, footer_buf[10..12], &.{ 'Y', 'Z' })) return null;

    const backward_size_encoded = std.mem.readInt(u32, footer_buf[4..8], .little);
    const index_size = (@as(u64, backward_size_encoded) + 1) * 4;
    if (file_size < 12 + index_size) return null;

    const index_offset = file_size - 12 - index_size;
    try r.seekTo(index_offset);

    const indicator = try r.interface.takeByte();
    if (indicator != 0x00) return null;

    const record_count = try r.interface.takeLeb128(u64);
    var total_uncompressed: u64 = 0;
    var i: usize = 0;
    while (i < record_count) : (i += 1) {
        _ = try r.interface.takeLeb128(u64);
        const uncompressed_size = try r.interface.takeLeb128(u64);
        total_uncompressed += uncompressed_size;
    }
    return total_uncompressed;
}

pub fn extractTarXz(
    io: std.Io,
    gpa: std.mem.Allocator,
    archive_path: []const u8,
    dest_path: []const u8,
) !void {
    var archive_file = try std.Io.Dir.openFileAbsolute(io, archive_path, .{});
    defer archive_file.close(io);

    const stat = try archive_file.stat(io);
    const total_archive_size = stat.size;
    const total_uncompressed = readXZUncompressedSize(io, archive_file, total_archive_size) catch null;

    var dest_dir = try std.Io.Dir.openDirAbsolute(io, dest_path, .{});
    defer dest_dir.close(io);

    var f_buf: [262144]u8 = undefined;
    var file_reader = archive_file.reader(io, &f_buf);
    try file_reader.seekTo(0);

    const decompress_buf = try gpa.alloc(u8, 4194304);
    var xz_stream = try std.compress.xz.Decompress.init(&file_reader.interface, gpa, decompress_buf);
    defer xz_stream.deinit();

    var file_name_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var link_name_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&xz_stream.reader, .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &link_name_buffer,
    });
    var copy_buf: [262144]u8 = undefined;

    var last_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var last_dir_len: usize = 0;
    var last_update: i128 = 0;
    var entry_count: usize = 0;
    var uncompressed_extracted: u64 = 0;

    while (try it.next()) |file| {
        entry_count += 1;
        uncompressed_extracted += file.size + 512;

        const now = std.Io.Clock.now(.awake, io).nanoseconds;
        if (now - last_update > 100_000_000) {
            last_update = now;
            if (total_uncompressed) |total| {
                if (total > 0) {
                    const pct = (@as(f64, @floatFromInt(uncompressed_extracted)) / @as(f64, @floatFromInt(total))) * 100.0;
                    printProgress(io, "\rExtracting: {d:.1}% ({d} files)", .{ @min(pct, 99.9), entry_count });
                } else {
                    printProgress(io, "\rExtracting: {d} files", .{entry_count});
                }
            } else {
                printProgress(io, "\rExtracting: {d} files", .{entry_count});
            }
        }

        const slash_idx = std.mem.indexOfScalar(u8, file.name, '/') orelse continue;
        const rel_path = file.name[slash_idx + 1 ..];
        if (rel_path.len == 0) continue;

        switch (file.kind) {
            .directory => {
                ensureParentDir(io, dest_dir, &last_dir_buf, &last_dir_len, rel_path);
            },
            .file => {
                if (std.fs.path.dirname(rel_path)) |parent| {
                    ensureParentDir(io, dest_dir, &last_dir_buf, &last_dir_len, parent);
                }

                const is_exec = (file.mode & 0o111) != 0;
                const perms: std.Io.File.Permissions = if (is_exec) .executable_file else .default_file;

                var out_file = try dest_dir.createFile(io, rel_path, .{
                    .truncate = true,
                    .permissions = perms,
                });
                defer out_file.close(io);

                var out_w = out_file.writer(io, &copy_buf);
                try it.streamRemaining(file, &out_w.interface);
                try out_w.interface.flush();
            },
            .sym_link => {
                if (std.fs.path.dirname(rel_path)) |parent| {
                    ensureParentDir(io, dest_dir, &last_dir_buf, &last_dir_len, parent);
                }
                dest_dir.deleteFile(io, rel_path) catch {};
                try dest_dir.symLink(io, file.link_name, rel_path, .{});
            },
        }
    }

    printProgress(io, "\rExtracting: 100.0% ({d} files)\n", .{entry_count});
}

fn ensureParentDir(
    io: std.Io,
    dest_dir: std.Io.Dir,
    last_dir_buf: *[std.fs.max_path_bytes]u8,
    last_dir_len: *usize,
    path: []const u8,
) void {
    if (path.len == last_dir_len.* and std.mem.eql(u8, last_dir_buf[0..last_dir_len.*], path)) {
        return;
    }

    var iter = std.mem.splitScalar(u8, path, '/');
    var accum_buf: [std.fs.max_path_bytes]u8 = undefined;
    var accum_len: usize = 0;

    while (iter.next()) |part| {
        if (part.len == 0) continue;
        if (accum_len > 0) {
            accum_buf[accum_len] = '/';
            accum_len += 1;
        }
        @memcpy(accum_buf[accum_len .. accum_len + part.len], part);
        accum_len += part.len;

        dest_dir.createDir(io, accum_buf[0..accum_len], .default_dir) catch {};
    }

    if (path.len <= last_dir_buf.len) {
        @memcpy(last_dir_buf[0..path.len], path);
        last_dir_len.* = path.len;
    }
}
