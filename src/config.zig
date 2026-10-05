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

    fn parseZon(
        comptime T: type,
        gpa: std.mem.Allocator,
        source_z: [:0]const u8,
        diag: ?*std.zon.parse.Diagnostics,
        ignore_unknown: bool,
    ) !T {
        if (@hasDecl(std.zon.parse, "fromSliceAlloc")) {
            return std.zon.parse.fromSliceAlloc(T, gpa, source_z, diag, .{
                .ignore_unknown_fields = ignore_unknown,
            });
        } else {
            const fn_info = @typeInfo(@TypeOf(std.zon.parse.fromSlice)).@"fn";
            const params_len = comptime if (@hasField(@TypeOf(fn_info), "param_types"))
                fn_info.param_types.len
            else if (@hasField(@TypeOf(fn_info), "params"))
                fn_info.params.len
            else
                2;
            if (params_len == 2) {
                var dummy_diag: std.zon.parse.Diagnostics = undefined;
                return std.zon.parse.fromSlice(T, .{
                    .gpa = gpa,
                    .arena = gpa,
                    .source = source_z,
                    .diagnostics = diag orelse &dummy_diag,
                    .ignore_unknown_fields = ignore_unknown,
                });
            } else {
                return std.zon.parse.fromSlice(T, gpa, source_z, diag, .{
                    .ignore_unknown_fields = ignore_unknown,
                });
            }
        }
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
                return try parseZon(Config, gpa, default_zon_z, null, false);
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

        return parseZon(Config, gpa, content_z, &diag, true) catch |e| {
            if (@hasDecl(std.zon.parse.Diagnostics, "log")) {
                diag.log(path);
            } else {
                std.log.err("Failed to parse ZON: {s}", .{path});
            }
            return e;
        };
    }
};
