const std = @import("std");
const dns = @import("dns.zig");

const Client = std.http.Client;
const Allocating = std.Io.Writer.Allocating;

pub const Index = struct {
    client: Client,

    const Self = @This();

    pub fn init(gpa: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) Self {
        var client = Client{ .allocator = gpa, .io = io };
        client.initDefaultProxies(gpa, environ_map) catch {};
        return Self{ .client = client };
    }

    pub fn fetchUrl(self: *Self, url_str: []const u8, body: *Allocating) !std.http.Status {
        const uri = try std.Uri.parse(url_str);
        return dns.fetch(&self.client, uri, &.{}, &body.writer);
    }

    pub fn deinit(self: *Self) void {
        self.client.deinit();
    }
};

pub const Source = struct {
    tarball: []const u8,
    shasum: []const u8,
    size: usize,

    pub fn deinit(self: Source, allocator: std.mem.Allocator) void {
        allocator.free(self.tarball);
        allocator.free(self.shasum);
    }
};

pub const Platform = struct {
    pub fn parse(platform: []const u8) ?[]const u8 {
        return platform;
    }
};

pub const VersionDetail = struct {
    date: []const u8 = "",
    object: std.json.Value,
};

pub const Type = struct {
    allocator: std.mem.Allocator,
    parsed: std.json.Parsed(std.json.ArrayHashMap(std.json.Value)),

    pub fn parse(allocator: std.mem.Allocator, json: []const u8) !Type {
        const parsed = try std.json.parseFromSlice(
            std.json.ArrayHashMap(std.json.Value),
            allocator,
            json,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
        return Type{ .allocator = allocator, .parsed = parsed };
    }

    pub fn loadCache(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Type {
        const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
        defer file.close(io);
        const stat = try file.stat(io);
        var f_buf: [65536]u8 = undefined;
        var r = file.reader(io, &f_buf);
        const content = try r.interface.readAlloc(allocator, @intCast(stat.size));
        defer allocator.free(content);
        return try parse(allocator, content);
    }

    pub fn saveCache(allocator: std.mem.Allocator, io: std.Io, path: []const u8, content: []const u8) !void {
        _ = allocator;
        if (std.fs.path.dirname(path)) |dir| {
            std.Io.Dir.createDirAbsolute(io, dir, .default_dir) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
        }
        var file = try std.Io.Dir.createFileAbsolute(io, path, .{});
        defer file.close(io);
        var f_buf: [65536]u8 = undefined;
        var writer = file.writer(io, &f_buf);
        try writer.interface.writeAll(content);
        try writer.flush();
    }

    pub fn get(self: Type, version: []const u8, platform: []const u8) ?Source {
        const ver_val = self.parsed.value.map.get(version) orelse return null;
        if (ver_val != .object) return null;
        const plat_val = ver_val.object.get(platform) orelse return null;
        const parsed_src = std.json.parseFromValue(Source, self.allocator, plat_val, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        defer parsed_src.deinit();
        return Source{
            .tarball = self.allocator.dupe(u8, parsed_src.value.tarball) catch return null,
            .shasum = self.allocator.dupe(u8, parsed_src.value.shasum) catch return null,
            .size = parsed_src.value.size,
        };
    }

    pub fn deinit(self: Type) void {
        self.parsed.deinit();
    }
};
