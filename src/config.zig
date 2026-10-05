const std = @import("std");

pub const Config = struct {
    pub const MirrorEntry = struct {
        name: []const u8,
        url: []const u8,
    };

    mirrors: []const MirrorEntry,
    defaultMirror: []const u8,

    pub const default_zon =
        \\.{
        \\    .mirrors = .{
        \\        .{ .name = "ziglang", .url = "https://ziglang.org/download/index.json" },
        \\        .{ .name = "mach", .url = "https://pkg.hexops.org/zig/index.json" },
        \\    },
        \\    .defaultMirror = "ziglang",
        \\}
    ;

    pub fn getMirrorUrl(self: Config, name: []const u8) ?[]const u8 {
        for (self.mirrors) |m| {
            if (std.mem.eql(u8, m.name, name)) return m.url;
        }
        return null;
    }

    pub fn loadOrInit(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
        const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (std.fs.path.dirname(path)) |dir_path| {
                    std.Io.Dir.createDirAbsolute(io, dir_path, .default_dir) catch |e| switch (e) {
                        error.PathAlreadyExists => {},
                        else => return e,
                    };
                }
                var f = try std.Io.Dir.createFileAbsolute(io, path, .{});
                defer f.close(io);
                var writer = f.writer(io, &.{});
                try writer.interface.writeAll(default_zon);

                // For the default case, parse default_zon
                const default_zon_z = try gpa.dupeSentinel(u8, default_zon, 0);
                defer gpa.free(default_zon_z);
                var diag: std.zon.parse.Diagnostics = undefined;
                return try std.zon.parse.fromSlice(Config, .{
                    .gpa = gpa,
                    .arena = gpa,
                    .source = default_zon_z,
                    .diagnostics = &diag,
                });
            },
            else => return err,
        };
        defer file.close(io);

        const stat = try file.stat(io);
        var f_buf: [65536]u8 = undefined;
        var r = file.reader(io, &f_buf);
        const content = try r.interface.readAlloc(gpa, @intCast(stat.size));
        defer gpa.free(content);

        const content_z = try gpa.dupeSentinel(u8, content, 0);
        defer gpa.free(content_z);

        var diag: std.zon.parse.Diagnostics = undefined;

        return std.zon.parse.fromSlice(Config, .{
            .gpa = gpa,
            .arena = gpa,
            .source = content_z,
            .diagnostics = &diag,
            .ignore_unknown_fields = true,
        }) catch |e| {
            diag.log(path);
            return e;
        };
    }
};
