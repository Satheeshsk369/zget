const std = @import("std");

pub fn extractTarXz(
    io: std.Io,
    gpa: std.mem.Allocator,
    archive_path: []const u8,
    dest_path: []const u8,
) !void {
    var archive_file = try std.Io.Dir.openFileAbsolute(io, archive_path, .{});
    defer archive_file.close(io);

    var dest_dir = try std.Io.Dir.openDirAbsolute(io, dest_path, .{});
    defer dest_dir.close(io);

    var f_buf: [262144]u8 = undefined;
    var file_reader = archive_file.reader(io, &f_buf);

    const decompress_buf = try gpa.alloc(u8, 2097152);
    var xz_stream = try std.compress.xz.Decompress.init(&file_reader.interface, gpa, decompress_buf);
    defer xz_stream.deinit();

    var dir_cache = std.StringHashMap(void).init(gpa);
    defer {
        var it = dir_cache.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        dir_cache.deinit();
    }

    var file_name_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var link_name_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&xz_stream.reader, .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &link_name_buffer,
    });
    var copy_buf: [65536]u8 = undefined;

    while (try it.next()) |file| {
        // Strip the leading root component (e.g., "zig-linux-aarch64-0.18.0-dev.../")
        const slash_idx = std.mem.indexOfScalar(u8, file.name, '/') orelse continue;
        const rel_path = file.name[slash_idx + 1 ..];
        if (rel_path.len == 0) continue;

        switch (file.kind) {
            .directory => {
                try ensureDirCached(io, dest_dir, gpa, &dir_cache, rel_path);
            },
            .file => {
                if (std.fs.path.dirname(rel_path)) |parent| {
                    try ensureDirCached(io, dest_dir, gpa, &dir_cache, parent);
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
                    try ensureDirCached(io, dest_dir, gpa, &dir_cache, parent);
                }
                dest_dir.deleteFile(io, rel_path) catch {};
                try dest_dir.symLink(io, file.link_name, rel_path, .{});
            },
        }
    }
}

fn ensureDirCached(
    io: std.Io,
    dest_dir: std.Io.Dir,
    gpa: std.mem.Allocator,
    dir_cache: *std.StringHashMap(void),
    rel_path: []const u8,
) !void {
    if (dir_cache.contains(rel_path)) return;

    var iter = std.mem.splitScalar(u8, rel_path, '/');
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

        const sub = accum_buf[0..accum_len];
        if (!dir_cache.contains(sub)) {
            dest_dir.createDir(io, sub, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
            const owned = try gpa.dupe(u8, sub);
            try dir_cache.put(owned, {});
        }
    }
}
