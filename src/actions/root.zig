const std = @import("std");
const Schema = @import("../schema.zig");
const command = @import("../command.zig");
const config = @import("../config.zig");

pub const Command = command.Command;
pub const Mirror = Schema.Index.Mirror;
pub const extract = @import("../extract.zig");

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
            .config => &.{ "APPDATA", "zget", "config.zon" },
            .cache => &.{ "LOCALAPPDATA", "zget", "cache" },
            .data => &.{ "LOCALAPPDATA", "zget" },
            .bin => &.{ "LOCALAPPDATA", "zget", "bin" },
        },
        else => switch (folder) {
            .config => &.{ "XDG_CONFIG_HOME", ".config", "zget", "config.zon" },
            .cache => &.{ "XDG_CACHE_HOME", ".cache", "zget" },
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

pub fn getActiveVersion(ctx: Context) !?[]const u8 {
    const binDir = try ctx.binDir();
    const builtin = @import("builtin");
    const exe_name = if (comptime builtin.os.tag == .windows) "zig.exe" else "zig";
    const exe_path = try std.fs.path.join(ctx.arena, &.{ binDir, exe_name });

    if (comptime builtin.os.tag == .windows) {
        const active_file_path = try std.fs.path.join(ctx.arena, &.{ binDir, "active_version" });
        var af = std.Io.Dir.openFileAbsolute(ctx.io, active_file_path, .{}) catch return null;
        defer af.close(ctx.io);
        var buf: [64]u8 = undefined;
        var r = af.reader(ctx.io, &buf);
        var val_buf: [64]u8 = undefined;
        const n = r.interface.readSliceShort(&val_buf) catch return null;
        if (n == 0) return null;
        return try ctx.arena.dupe(u8, std.mem.trim(u8, val_buf[0..n], " \r\n\t"));
    }

    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.readLinkAbsolute(ctx.io, exe_path, &link_buf) catch return null;
    const target = link_buf[0..len];

    if (std.fs.path.dirname(target)) |dir| {
        const ver = std.fs.path.basename(dir);
        if (ver.len > 0 and !std.mem.eql(u8, ver, ".") and !std.mem.eql(u8, ver, "/")) {
            return try ctx.arena.dupe(u8, ver);
        }
    }
    return null;
}

pub fn runCurrent(ctx: Context) !void {
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

pub fn runEnv(ctx: Context) !void {
    std.debug.print(
        \\.{{
        \\    .ZGET = "{s}",
        \\    .BIN = "{s}",
        \\    .CONFIG = "{s}",
        \\    .DATA = "{s}",
        \\    .CACHE = "{s}",
        \\}}
        \\
    , .{
        std.process.executablePathAlloc(ctx.io, ctx.arena) catch "zget",
        try ctx.binDir(),
        try configPath(ctx.arena, ctx.environMap),
        try ctx.dataDir(),
        try ctx.cacheDir(),
    });
}

pub fn runClean(ctx: Context) !void {
    const cache_dir = try ctx.cacheDir();
    var dir = std.Io.Dir.openDirAbsolute(ctx.io, cache_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            std.log.info("Cache directory is already clean.", .{});
            return;
        }
        return err;
    };
    defer dir.close(ctx.io);

    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(ctx.io)) |entry| {
        if (entry.kind == .file) {
            dir.deleteFile(ctx.io, entry.name) catch continue;
            count += 1;
        } else if (entry.kind == .directory) {
            dir.deleteTree(ctx.io, entry.name) catch continue;
            count += 1;
        }
    }

    std.log.info("Cleaned {d} items from cache ({s}).", .{ count, cache_dir });
}

pub fn runSet(ctx: Context, ver: []const u8) !void {
    const binDir = try ctx.binDir();
    const installDir = try ctx.versionDir(ver);

    if (!dirExists(ctx, installDir)) {
        std.log.err("Version {s} is not installed. Please run 'zget install {s}' first.", .{ ver, ver });
        return error.FileNotFound;
    }

    try ensureDir(ctx.io, binDir);

    const builtin = @import("builtin");
    const exe_name = if (comptime builtin.os.tag == .windows) "zig.exe" else "zig";
    const targetExe = try std.fs.path.join(ctx.arena, &.{ installDir, exe_name });
    const targetRel = std.fs.path.relativeAlloc(ctx.arena, binDir, ctx.environMap, binDir, targetExe) catch targetExe;

    var bd = try std.Io.Dir.openDirAbsolute(ctx.io, binDir, .{});
    defer bd.close(ctx.io);
    bd.deleteFile(ctx.io, exe_name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try bd.symLink(ctx.io, targetRel, exe_name, .{});

    if (comptime builtin.os.tag == .windows) {
        // Write active version marker so 'zigup current' can also resolve reliably
        const active_file_path = try std.fs.path.join(ctx.arena, &.{ binDir, "active_version" });
        var af = try std.Io.Dir.createFileAbsolute(ctx.io, active_file_path, .{ .truncate = true });
        defer af.close(ctx.io);
        try af.writeStreamingAll(ctx.io, ver);
    }
    std.log.info("Set {s} as default.", .{ver});
}

pub fn runDelete(ctx: Context, ver: []const u8) !void {
    const installDir = try ctx.versionDir(ver);
    if (!dirExists(ctx, installDir)) return error.FileNotFound;

    if (getActiveVersion(ctx) catch null) |active| {
        if (std.mem.eql(u8, active, ver)) {
            const binDir = try ctx.binDir();
            var bd = std.Io.Dir.openDirAbsolute(ctx.io, binDir, .{}) catch null;
            if (bd) |*d| {
                defer d.close(ctx.io);
                const builtin = @import("builtin");
                const exe_name = if (comptime builtin.os.tag == .windows) "zig.exe" else "zig";
                d.deleteFile(ctx.io, exe_name) catch {};
            }
            std.log.warn("Version {s} was the active default; default link removed.", .{ver});
        }
    }

    const data_dir = try ctx.dataDir();
    var zd = try std.Io.Dir.openDirAbsolute(ctx.io, data_dir, .{});
    defer zd.close(ctx.io);

    try zd.deleteTree(ctx.io, ver);

    std.log.info("Successfully deleted {s}.", .{ver});
}

pub fn run(cmd: Command, ctx: Context) ActionError!void {
    switch (cmd) {
        .help => @import("help.zig").run(),
        .version => {
            const stdout = std.Io.File.stdout();
            stdout.writeStreamingAll(ctx.io, @import("options").version ++ "\n") catch {};
        },
        .env => runEnv(ctx) catch |e| switch (e) {
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
        .set => |ver| runSet(ctx, ver) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.HomeNotFound, error.EnvironmentVariableNotFound => return error.EnvironmentVariableNotFound,
            error.AccessDenied => return error.AccessDenied,
            error.FileNotFound => return error.FileNotFound,
            else => return error.FileNotFound,
        },
        .delete => |ver| runDelete(ctx, ver) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.HomeNotFound, error.EnvironmentVariableNotFound => return error.EnvironmentVariableNotFound,
            error.AccessDenied => return error.AccessDenied,
            error.FileNotFound => return error.FileNotFound,
            else => return error.FileNotFound,
        },
        .update => |ver| @import("update.zig").run(ctx, ver) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.HomeNotFound, error.EnvironmentVariableNotFound => return error.EnvironmentVariableNotFound,
            error.AccessDenied => return error.AccessDenied,
            error.FileNotFound => return error.FileNotFound,
            else => return error.HttpError,
        },
        .current => runCurrent(ctx) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.HomeNotFound, error.EnvironmentVariableNotFound => return error.EnvironmentVariableNotFound,
        },
        .clean => runClean(ctx) catch |e| switch (e) {
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
    if (std.mem.eql(u8, cmd, "update") or std.mem.eql(u8, cmd, "up")) {
        if (args.len >= 3) {
            return Command{ .update = args[2] };
        }
        return Command{ .update = "" };
    }
    if (std.mem.eql(u8, cmd, "current") or std.mem.eql(u8, cmd, "c") or std.mem.eql(u8, cmd, "which")) return .current;
    if (std.mem.eql(u8, cmd, "clean") or std.mem.eql(u8, cmd, "cl")) return .clean;
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

