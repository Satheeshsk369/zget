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

pub const ZipFileEntry = struct {
    data_offset: u64,
    compressed_size: u64,
    uncompressed_size: u64,
    compression_method: std.zip.CompressionMethod,
    rel_path: []const u8,
};

const ZipWorkerContext = struct {
    io: std.Io,
    archive_path: []const u8,
    dest_path: []const u8,
    entries: []const ZipFileEntry,
    next_idx: *std.atomic.Value(usize),
    completed_files: *std.atomic.Value(usize),
    completed_bytes: *std.atomic.Value(u64),
};

fn zipWorkerFn(ctx: *const ZipWorkerContext) void {
    const io = ctx.io;
    var archive_file = std.Io.Dir.openFileAbsolute(io, ctx.archive_path, .{}) catch return;
    defer archive_file.close(io);

    var dest_dir = std.Io.Dir.openDirAbsolute(io, ctx.dest_path, .{}) catch return;
    defer dest_dir.close(io);

    var f_buf: [131072]u8 = undefined;
    var file_reader = archive_file.reader(io, &f_buf);

    var copy_buf: [131072]u8 = undefined;
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;

    while (true) {
        const idx = ctx.next_idx.fetchAdd(1, .monotonic);
        if (idx >= ctx.entries.len) break;

        const entry = ctx.entries[idx];

        file_reader.seekTo(entry.data_offset) catch continue;

        var out_file = dest_dir.createFile(io, entry.rel_path, .{ .truncate = true }) catch continue;
        defer out_file.close(io);

        var out_writer = out_file.writer(io, &copy_buf);

        switch (entry.compression_method) {
            .store => {
                file_reader.interface.streamExact64(&out_writer.interface, entry.uncompressed_size) catch continue;
                out_writer.interface.flush() catch continue;
            },
            .deflate => {
                var decompressor = std.compress.flate.Decompress.init(&file_reader.interface, .raw, &decompress_buf);
                decompressor.reader.streamExact64(&out_writer.interface, entry.uncompressed_size) catch continue;
                out_writer.interface.flush() catch continue;
            },
            _ => continue,
        }

        _ = ctx.completed_files.fetchAdd(1, .monotonic);
        _ = ctx.completed_bytes.fetchAdd(entry.uncompressed_size, .monotonic);
    }
}

pub fn extractZipStripMultiThread(
    io: std.Io,
    gpa: std.mem.Allocator,
    archive_path: []const u8,
    dest_path: []const u8,
) !void {
    var archive_file = try std.Io.Dir.openFileAbsolute(io, archive_path, .{});
    defer archive_file.close(io);

    var dest_dir = try std.Io.Dir.openDirAbsolute(io, dest_path, .{});
    defer dest_dir.close(io);

    var f_buf: [131072]u8 = undefined;
    var file_reader = archive_file.reader(io, &f_buf);

    var iter = try std.zip.Iterator.init(&file_reader);
    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;

    var dir_set = std.StringHashMap(void).init(gpa);
    defer {
        var it = dir_set.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        dir_set.deinit();
    }

    var files = std.ArrayList(ZipFileEntry).empty;
    defer {
        for (files.items) |e| gpa.free(e.rel_path);
        files.deinit(gpa);
    }

    var total_uncompressed_bytes: u64 = 0;

    while (try iter.next()) |entry| {
        if (filename_buf.len < entry.filename_len)
            return error.ZipInsufficientBuffer;

        const filename = filename_buf[0..entry.filename_len];
        try file_reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        try file_reader.interface.readSliceAll(filename);

        std.mem.replaceScalar(u8, filename, '\\', '/');

        const slash_idx = std.mem.indexOfScalar(u8, filename, '/') orelse continue;
        const stripped_filename = filename[slash_idx + 1 ..];
        if (stripped_filename.len == 0) continue;

        const is_dir = filename[filename.len - 1] == '/';
        const dir_to_add = if (is_dir)
            stripped_filename[0 .. stripped_filename.len - 1]
        else
            std.fs.path.dirname(stripped_filename);

        if (dir_to_add) |dir_path| {
            if (dir_path.len > 0 and !dir_set.contains(dir_path)) {
                const key = try gpa.dupe(u8, dir_path);
                try dir_set.put(key, {});
            }
        }

        if (is_dir) continue;

        const local_data_header_offset: u64 = local_data_header_offset: {
            const local_header = blk: {
                try file_reader.seekTo(entry.file_offset);
                break :blk try file_reader.interface.takeStruct(std.zip.LocalFileHeader, .little);
            };
            if (!std.mem.eql(u8, &local_header.signature, &std.zip.local_file_header_sig))
                return error.ZipBadFileOffset;
            if (local_header.version_needed_to_extract != entry.version_needed_to_extract)
                return error.ZipMismatchVersionNeeded;
            if (local_header.last_modification_time != entry.last_modification_time)
                return error.ZipMismatchModTime;
            if (local_header.last_modification_date != entry.last_modification_date)
                return error.ZipMismatchModDate;

            break :local_data_header_offset @as(u64, local_header.filename_len) +
                @as(u64, local_header.extra_len);
        };

        const data_offset = entry.file_offset + @sizeOf(std.zip.LocalFileHeader) + local_data_header_offset;

        const path_dup = try gpa.dupe(u8, stripped_filename);
        try files.append(gpa, .{
            .data_offset = data_offset,
            .compressed_size = entry.compressed_size,
            .uncompressed_size = entry.uncompressed_size,
            .compression_method = entry.compression_method,
            .rel_path = path_dup,
        });
        total_uncompressed_bytes += entry.uncompressed_size;
    }

    // Sort directories by path length to ensure parents are created before subdirectories
    var dir_keys = try gpa.alloc([]const u8, dir_set.count());
    defer gpa.free(dir_keys);
    var key_idx: usize = 0;
    var kit = dir_set.keyIterator();
    while (kit.next()) |k| {
        dir_keys[key_idx] = k.*;
        key_idx += 1;
    }

    const sortFn = struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return a.len < b.len;
        }
    }.lessThan;
    std.mem.sort([]const u8, dir_keys, {}, sortFn);

    for (dir_keys) |dir_path| {
        dest_dir.createDirPath(io, dir_path) catch {};
    }

    const num_threads = @min(std.Thread.getCpuCount() catch 4, 16);

    var next_idx = std.atomic.Value(usize).init(0);
    var completed_files = std.atomic.Value(usize).init(0);
    var completed_bytes = std.atomic.Value(u64).init(0);

    const worker_ctx = ZipWorkerContext{
        .io = io,
        .archive_path = archive_path,
        .dest_path = dest_path,
        .entries = files.items,
        .next_idx = &next_idx,
        .completed_files = &completed_files,
        .completed_bytes = &completed_bytes,
    };

    var threads = try gpa.alloc(std.Thread, num_threads);
    defer gpa.free(threads);

    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, zipWorkerFn, .{&worker_ctx});
    }

    // Progress reporter on main thread
    const total_files = files.items.len;
    while (true) {
        const done = completed_files.load(.monotonic);
        const bytes_done = completed_bytes.load(.monotonic);

        if (total_uncompressed_bytes > 0) {
            const pct = (@as(f64, @floatFromInt(bytes_done)) / @as(f64, @floatFromInt(total_uncompressed_bytes))) * 100.0;
            printProgress(io, "\rExtracting: {d:.1}% ({d}/{d} files)", .{ @min(pct, 99.9), done, total_files });
        } else {
            printProgress(io, "\rExtracting: {d}/{d} files", .{ done, total_files });
        }

        if (done >= total_files) break;

        // Sleep 100ms
        std.Io.Clock.Duration.sleep(.{
            .clock = .awake,
            .raw = .fromNanoseconds(100 * std.time.ns_per_ms),
        }, io) catch {};
    }

    for (threads) |t| {
        t.join();
    }

    printProgress(io, "\rExtracting: 100.0% ({d}/{d} files)\n", .{ total_files, total_files });
}
