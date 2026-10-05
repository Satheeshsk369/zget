const std = @import("std");
const Schema = @import("../schema.zig");
const command = @import("../command.zig");
const config = @import("../config.zig");

pub const Command = command.Command;
pub const Mirror = Schema.Index.Mirror;

pub const ActionError = error{
    HomeNotFound,
    EnvironmentVariableNotFound,
    OutOfMemory,
    AccessDenied,
    FileNotFound,
    PathAlreadyExists,
    ZipInsufficientBuffer,
    ZipCorrupted,
    HttpError,
    MirrorNotFound,
    ConfigParseError,
    SignatureVerificationFailed,
    MinisignFilenameMismatch,
    InvalidMinisignFormat,
    UnsupportedMinisignAlgorithm,
    InvalidPublicKey,
};

pub const Folder = enum { config, cache, data, bin };

pub fn getPlatformPath(comptime folder: Folder) []const []const u8 {
    const builtin = @import("builtin");
    return switch (builtin.os.tag) {
        .windows => switch (folder) {
            .config => &.{ "APPDATA", "zigup", "config.zon" },
            .cache => &.{ "LOCALAPPDATA", "zigup", "cache" },
            .data => &.{ "LOCALAPPDATA", "zigup" },
            .bin => &.{ "LOCALAPPDATA", "zigup", "bin" },
        },
        else => switch (folder) {
            .config => &.{ "XDG_CONFIG_HOME", ".config", "zigup", "config.zon" },
            .cache => &.{ "XDG_CACHE_HOME", ".cache", "zigup" },
            .data => &.{ "XDG_DATA_HOME", ".local", "share", "zig" },
            .bin => &.{ "HOME", ".local", "bin" },
        },
    };
}

pub const Context = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    environMap: *const std.process.Environ.Map,
    pathEnv: []const u8,
    userConfig: config.Config,
    args: []const []const u8,
    sync: bool,

    fn resolvePath(self: Context, comptime folder: Folder) ![]const u8 {
        const parts = getPlatformPath(folder);
        const env_name = parts[0];

        var base_dir: []const u8 = undefined;
        var static_parts: []const []const u8 = undefined;

        if (self.environMap.get(env_name)) |val| {
            base_dir = val;
            static_parts = if (std.mem.startsWith(u8, env_name, "XDG_")) parts[2..] else parts[1..];
        } else {
            if (std.mem.startsWith(u8, env_name, "XDG_")) {
                const home = self.environMap.get("HOME") orelse return error.HomeNotFound;
                base_dir = try std.fs.path.join(self.arena, &.{ home, parts[1] });
                static_parts = parts[2..];
            } else {
                const builtin = @import("builtin");
                if (builtin.os.tag == .windows) {
                    const userprofile = self.environMap.get("USERPROFILE") orelse self.environMap.get("HOME") orelse return error.HomeNotFound;
                    if (std.mem.eql(u8, env_name, "LOCALAPPDATA")) {
                        base_dir = try std.fs.path.join(self.arena, &.{ userprofile, "AppData", "Local" });
                        static_parts = parts[1..];
                    } else if (std.mem.eql(u8, env_name, "APPDATA")) {
                        base_dir = try std.fs.path.join(self.arena, &.{ userprofile, "AppData", "Roaming" });
                        static_parts = parts[1..];
                    } else {
                        return error.EnvironmentVariableNotFound;
                    }
                } else {
                    return error.EnvironmentVariableNotFound;
                }
            }
        }

        if (static_parts.len == 0) return base_dir;

        var list = std.ArrayList([]const u8).empty;
        try list.append(self.arena, base_dir);
        try list.appendSlice(self.arena, static_parts);
        return std.fs.path.join(self.arena, list.items);
    }

    pub fn cacheFile(self: Context, mirror: []const u8) ![]const u8 {
        const base = try self.resolvePath(.cache);
        try ensureDir(self.io, base);
        const filename = try std.fmt.allocPrint(self.arena, "{s}.json", .{mirror});
        return std.fs.path.join(self.arena, &.{ base, filename });
    }

    pub fn dataDir(self: Context) ![]const u8 {
        return self.resolvePath(.data);
    }

    pub fn versionDir(self: Context, ver: []const u8) ![]const u8 {
        return std.fs.path.join(self.arena, &.{ try self.dataDir(), ver });
    }

    pub fn binDir(self: Context) ![]const u8 {
        return self.resolvePath(.bin);
    }

    pub fn configDir(self: Context) ![]const u8 {
        const path = try configPath(self.arena, self.environMap);
        return std.fs.path.dirname(path) orelse path;
    }

    pub fn cacheDir(self: Context) ![]const u8 {
        return self.resolvePath(.cache);
    }
};

pub fn configPath(arena: std.mem.Allocator, environMap: *const std.process.Environ.Map) ![]const u8 {
    const parts = getPlatformPath(.config);
    const env_name = parts[0];
    const env_val = environMap.get(env_name) orelse {
        if (std.mem.startsWith(u8, env_name, "XDG_")) {
            const home = environMap.get("HOME") orelse return error.HomeNotFound;
            const fallback_base = try std.fs.path.join(arena, &.{ home, parts[1] });
            return try std.fs.path.join(arena, &.{ fallback_base, parts[2], parts[3] });
        }
        const builtin = @import("builtin");
        if (builtin.os.tag == .windows) {
            const userprofile = environMap.get("USERPROFILE") orelse environMap.get("HOME") orelse return error.HomeNotFound;
            if (std.mem.eql(u8, env_name, "APPDATA")) {
                const fallback_base = try std.fs.path.join(arena, &.{ userprofile, "AppData", "Roaming" });
                return try std.fs.path.join(arena, &.{ fallback_base, parts[1], parts[2] });
            }
        }
        return error.EnvironmentVariableNotFound;
    };

    const static_parts = if (std.mem.startsWith(u8, env_name, "XDG_")) parts[2..] else parts[1..];
    if (static_parts.len == 0) return env_val;

    var list = std.ArrayList([]const u8).empty;
    try list.append(arena, env_val);
    try list.appendSlice(arena, static_parts);
    return std.fs.path.join(arena, list.items);
}

pub fn targetKey() []const u8 {
    const builtin = @import("builtin");
    return @tagName(builtin.target.cpu.arch) ++ "-" ++ @tagName(builtin.target.os.tag);
}

pub fn dirExists(ctx: Context, path: []const u8) bool {
    if (std.Io.Dir.openDirAbsolute(ctx.io, path, .{})) |*d| {
        d.close(ctx.io);
        return true;
    } else |_| return false;
}

pub fn ensureDir(io: std.Io, path: []const u8) !void {
    std.Io.Dir.createDirAbsolute(io, path, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => {
            std.log.err("directory '{s}' missing: {s}", .{ path, @errorName(e) });
            return e;
        },
    };
}

pub fn run(cmd: Command, ctx: Context) ActionError!void {
    switch (cmd) {
        .help => @import("help.zig").run(),
        .version => {
            const stdout = std.Io.File.stdout();
            stdout.writeStreamingAll(ctx.io, @import("options").version ++ "\n") catch {};
        },
        .env => @import("env.zig").run(ctx) catch |e| switch (e) {
            error.HomeNotFound, error.EnvironmentVariableNotFound => return error.EnvironmentVariableNotFound,
            error.OutOfMemory => return error.OutOfMemory,
        },
        .list => |mirror| @import("list.zig").run(ctx, mirror) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.HomeNotFound, error.EnvironmentVariableNotFound => return error.EnvironmentVariableNotFound,
            error.AccessDenied => return error.AccessDenied,
            error.FileNotFound => return error.FileNotFound,
            else => return error.FileNotFound,
        },
        .install => |ver| @import("install.zig").run(ctx, ver) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.HomeNotFound, error.EnvironmentVariableNotFound => return error.EnvironmentVariableNotFound,
            error.AccessDenied => return error.AccessDenied,
            error.FileNotFound => return error.FileNotFound,
            error.ZipInsufficientBuffer => return error.ZipInsufficientBuffer,
            error.PathAlreadyExists => return error.PathAlreadyExists,
            error.ZipBadFileOffset, error.ZipMismatchVersionNeeded, error.ZipMismatchModTime, error.ZipMismatchModDate => return error.ZipCorrupted,
            error.MirrorNotFound => return error.MirrorNotFound,
            else => return error.HttpError,
        },
        .set => |ver| @import("set.zig").run(ctx, ver) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.HomeNotFound, error.EnvironmentVariableNotFound => return error.EnvironmentVariableNotFound,
            error.AccessDenied => return error.AccessDenied,
            error.FileNotFound => return error.FileNotFound,
            else => return error.FileNotFound,
        },
        .delete => |ver| @import("delete.zig").run(ctx, ver) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.HomeNotFound, error.EnvironmentVariableNotFound => return error.EnvironmentVariableNotFound,
            error.AccessDenied => return error.AccessDenied,
            error.FileNotFound => return error.FileNotFound,
            else => return error.FileNotFound,
        },
        .update => @import("update.zig").run(ctx) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.HomeNotFound, error.EnvironmentVariableNotFound => return error.EnvironmentVariableNotFound,
            error.AccessDenied => return error.AccessDenied,
            error.FileNotFound => return error.FileNotFound,
            else => return error.HttpError,
        },
        .current => @import("current.zig").run(ctx) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.HomeNotFound, error.EnvironmentVariableNotFound => return error.EnvironmentVariableNotFound,
        },
        .clean => @import("clean.zig").run(ctx) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.HomeNotFound, error.EnvironmentVariableNotFound => return error.EnvironmentVariableNotFound,
            error.AccessDenied => return error.AccessDenied,
            else => return error.FileNotFound,
        },
        .run => |ver| @import("run.zig").run(ctx, ver) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.HomeNotFound, error.EnvironmentVariableNotFound => return error.EnvironmentVariableNotFound,
            error.AccessDenied => return error.AccessDenied,
            error.FileNotFound => return error.FileNotFound,
            else => return error.FileNotFound,
        },
    }
}
pub fn parseCommand(args: []const []const u8) ?Command {
    if (args.len < 2) return .help;
    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "h")) return .help;
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "v")) return .version;
    if (std.mem.eql(u8, cmd, "env") or std.mem.eql(u8, cmd, "e")) return .env;
    if (std.mem.eql(u8, cmd, "update") or std.mem.eql(u8, cmd, "up")) return .update;
    if (std.mem.eql(u8, cmd, "current") or std.mem.eql(u8, cmd, "c") or std.mem.eql(u8, cmd, "which")) return .current;
    if (std.mem.eql(u8, cmd, "clean")) return .clean;
    if (std.mem.eql(u8, cmd, "run") or std.mem.eql(u8, cmd, "r")) {
        if (args.len < 3) {
            std.log.err("command 'run' requires a version tag", .{});
            return .help;
        }
        return Command{ .run = args[2] };
    }
    if (std.mem.eql(u8, cmd, "install") or std.mem.eql(u8, cmd, "i")) {
        if (args.len < 3) {
            std.log.err("command 'install' requires a version tag", .{});
            return .help;
        }
        return Command{ .install = args[2] };
    }

    if (std.mem.eql(u8, cmd, "set") or std.mem.eql(u8, cmd, "s")) {
        if (args.len < 3) {
            std.log.err("command 'set' requires a version tag", .{});
            return .help;
        }
        return Command{ .set = args[2] };
    }
    if (std.mem.eql(u8, cmd, "delete") or std.mem.eql(u8, cmd, "d")) {
        if (args.len < 3) {
            std.log.err("command 'delete' requires a version tag", .{});
            return .help;
        }
        return Command{ .delete = args[2] };
    }

    if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "l")) {
        if (args.len >= 3) {
            return Command{ .list = args[2] };
        }
        return Command{ .list = "" };
    }

    return null;
}

pub fn extractZipStrip(io: std.Io, dest: std.Io.Dir, fr: *std.Io.File.Reader) !void {
    var iter = try std.zip.Iterator.init(fr);
    const total = iter.cd_record_count;
    std.log.info("Extracting {d} entries", .{total});
    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
    var extracted: u64 = 0;

    while (try iter.next()) |entry| {
        if (filename_buf.len < entry.filename_len)
            return error.ZipInsufficientBuffer;

        const filename = filename_buf[0..entry.filename_len];
        {
            try fr.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
            try fr.interface.readSliceAll(filename);
        }

        std.mem.replaceScalar(u8, filename, '\\', '/');

        const slash_idx = std.mem.indexOfScalar(u8, filename, '/') orelse continue;
        const stripped_filename = filename[slash_idx + 1 ..];
        if (stripped_filename.len == 0) continue;

        const local_data_header_offset: u64 = local_data_header_offset: {
            const local_header = blk: {
                try fr.seekTo(entry.file_offset);
                break :blk try fr.interface.takeStruct(std.zip.LocalFileHeader, .little);
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

        if (filename[filename.len - 1] == '/') {
            try dest.createDirPath(io, stripped_filename[0 .. stripped_filename.len - 1]);
            continue;
        }

        const out_file = blk: {
            if (std.fs.path.dirname(stripped_filename)) |dirname| {
                var parent_dir = try dest.createDirPathOpen(io, dirname, .{});
                defer parent_dir.close(io);
                break :blk try parent_dir.createFile(io, std.fs.path.basename(stripped_filename), .{});
            } else {
                break :blk try dest.createFile(io, stripped_filename, .{});
            }
        };
        defer out_file.close(io);

        try fr.seekTo(data_offset);

        switch (entry.compression_method) {
            .store => {
                var w = out_file.writer(io, &.{});
                try fr.interface.streamExact64(&w.interface, entry.uncompressed_size);
            },
            .deflate => {
                const decompress_buf = try std.heap.page_allocator.alloc(u8, std.compress.flate.max_window_len);
                defer std.heap.page_allocator.free(decompress_buf);

                var decompressor = std.compress.flate.Decompress.init(&fr.interface, .raw, decompress_buf);
                var out_writer = out_file.writer(io, &.{});
                try decompressor.reader.streamExact64(&out_writer.interface, entry.uncompressed_size);
            },
            _ => return error.UnsupportedCompressionMethod,
        }

        extracted += 1;
        if (extracted % 50 == 0 or extracted == total)
            std.log.info("Extracting: {d}/{d}", .{ extracted, total });
    }
}
