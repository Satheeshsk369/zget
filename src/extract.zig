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

    var file_name_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var link_name_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&xz_stream.reader, .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &link_name_buffer,
    });
    var copy_buf: [65536]u8 = undefined;

    var last_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var last_dir_len: usize = 0;

    while (try it.next()) |file| {
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
