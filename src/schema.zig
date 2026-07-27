const std = @import("std");
const adt = @import("adt.zig");

const Client = std.http.Client;
const Allocating = std.Io.Writer.Allocating;
const Set = adt.Set(null);

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
        const response = try self.client.fetch(.{
            .location = .{ .uri = uri },
            .method = .GET,
            .response_writer = &body.writer,
        });
        return response.status;
    }

    pub fn deinit(self: *Self) void {
        self.client.deinit();
    }
};

pub const Source = struct {
    tarball: []const u8,
    shasum: []const u8,
    size: usize,
};

pub const Arch = enum { x86_64, aarch64, arm, riscv64, powerpc64le, x86, loongarch64, s390x };
pub const OS = enum { macos, linux, windows, freebsd, netbsd, openbsd };

pub const Platform = struct {
    pub const Combination = Set.cartesianProduct(Arch, OS, .{ .separator = "-" });

    pub fn parse(platform: []const u8) ?Combination {
        return std.meta.stringToEnum(Combination, platform);
    }

    pub fn toUnion(comptime FieldType: type) type {
        return Set.enumToUnion(Combination, FieldType);
    }
};

pub const VersionDetail = decl: {
    const BaseEnum = enum { version, date, docs, notes, stdDocs, src, bootstrap };
    const BaseUnion = union(BaseEnum) {
        version: ?[]const u8,
        date: [10]u8,
        docs: ?[]const u8,
        notes: ?[]const u8,
        stdDocs: ?[]const u8,
        src: ?Source,
        bootstrap: ?Source,
    };
    const PlatformUnion = Platform.toUnion(?Source);
    break :decl Set.unionToStruct(Set.join(BaseUnion, PlatformUnion));
};

pub const Type = struct {
    parsed: std.json.Parsed(std.json.ArrayHashMap(VersionDetail)),

    pub fn parse(allocator: std.mem.Allocator, json: []const u8) !Type {
        const parsed = try std.json.parseFromSlice(
            std.json.ArrayHashMap(VersionDetail),
            allocator,
            json,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
        return Type{ .parsed = parsed };
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

    pub fn get(self: Type, version: []const u8, platform: Platform.Combination) ?Source {
        const detail = self.parsed.value.map.get(version) orelse return null;
        const target_name = @tagName(platform);
        const info = @typeInfo(VersionDetail).@"struct";
        inline for (info.fields) |f| {
            if (std.mem.eql(u8, f.name, target_name)) {
                if (f.type == ?Source) {
                    return @field(detail, f.name);
                }
            }
        }
        return null;
    }

    pub fn deinit(self: Type) void {
        self.parsed.deinit();
    }
};
