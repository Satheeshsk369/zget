const std = @import("std");

var dns_cache: std.StringHashMapUnmanaged([]const u8) = .{};

pub fn resolve(allocator: std.mem.Allocator, io: std.Io, host: []const u8) ![]const u8 {
    // 1. If host is already an IP address, return a duplicate
    if (std.Io.net.Ip4Address.parse(host, 0)) |_| return try allocator.dupe(u8, host) else |_| {}
    if (std.Io.net.Ip6Address.parse(host, 0)) |_| return try allocator.dupe(u8, host) else |_| {}

    // 2. Check in-memory cache
    if (dns_cache.get(host)) |cached_ip| {
        return try allocator.dupe(u8, cached_ip);
    }

    // 3. Collect nameservers
    var ns_list: [4][4]u8 = .{
        .{ 8, 8, 8, 8 },
        .{ 1, 1, 1, 1 },
        .{ 8, 8, 4, 4 },
        .{ 1, 0, 0, 1 },
    };
    var ns_count: usize = 0;

    const conf_paths = [_][]const u8{
        "/data/data/com.termux/files/usr/etc/resolv.conf",
        "/etc/resolv.conf",
    };
    for (conf_paths) |path| {
        var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch continue;
        defer file.close(io);
        var f_buf: [1024]u8 = undefined;
        var r = file.reader(io, &f_buf);
        while (r.interface.takeDelimiter('\n') catch null) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, trimmed, "nameserver")) {
                var words = std.mem.tokenizeAny(u8, trimmed, " \t");
                _ = words.next();
                if (words.next()) |ip_str| {
                    if (std.Io.net.Ip4Address.parse(ip_str, 53)) |addr| {
                        const bytes = @as(*const [4]u8, @ptrCast(&addr.bytes));
                        if (ns_count < 4) {
                            ns_list[ns_count] = bytes.*;
                            ns_count += 1;
                        }
                    } else |_| {}
                }
            }
        }
        if (ns_count > 0) break;
    }
    if (ns_count == 0) ns_count = 2; // fallback to 8.8.8.8, 1.1.1.1

    // 4. Build DNS query packet (A record) with random Query ID
    var packet: [512]u8 = undefined;
    const now = std.Io.Clock.real.now(io).nanoseconds;
    var prng = std.Random.DefaultPrng.init(@truncate(@as(u96, @bitCast(now))));
    const qid = prng.random().int(u16);
    std.mem.writeInt(u16, packet[0..2], qid, .big);
    packet[2] = 0x01; // RD = 1
    packet[3] = 0x00;
    packet[4] = 0x00;
    packet[5] = 0x01; // QDCOUNT = 1
    @memset(packet[6..12], 0);

    var pos: usize = 12;
    var label_it = std.mem.splitScalar(u8, host, '.');
    while (label_it.next()) |label| {
        if (label.len == 0 or label.len > 63) return error.InvalidHost;
        packet[pos] = @intCast(label.len);
        pos += 1;
        @memcpy(packet[pos .. pos + label.len], label);
        pos += label.len;
    }
    packet[pos] = 0;
    pos += 1;
    // QTYPE = A (1)
    packet[pos] = 0x00;
    packet[pos + 1] = 0x01;
    // QCLASS = IN (1)
    packet[pos + 2] = 0x00;
    packet[pos + 3] = 0x01;
    pos += 4;

    const query = packet[0..pos];

    // 5. Send query to nameservers
    for (ns_list[0..ns_count]) |ns| {
        const sock_rc = std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
        if (std.posix.errno(sock_rc) != .SUCCESS) continue;
        const sock: std.posix.fd_t = @intCast(sock_rc);
        defer _ = std.posix.system.close(sock);

        const timeout = std.posix.timeval{ .sec = 2, .usec = 0 };
        _ = std.posix.system.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, @ptrCast(&timeout), @sizeOf(std.posix.timeval));

        var dest_addr = std.posix.sockaddr.in{
            .family = std.posix.AF.INET,
            .port = std.mem.nativeToBig(u16, 53),
            .addr = @as(u32, @bitCast(ns)),
        };

        const sent = std.posix.system.sendto(sock, query.ptr, query.len, 0, @ptrCast(&dest_addr), @sizeOf(std.posix.sockaddr.in));
        if (std.posix.errno(sent) != .SUCCESS) continue;

        var resp: [512]u8 = undefined;
        var src_addr: std.posix.sockaddr.in = undefined;
        var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
        const recv_rc = std.posix.system.recvfrom(sock, &resp, resp.len, 0, @ptrCast(&src_addr), &addr_len);
        if (std.posix.errno(recv_rc) != .SUCCESS) continue;
        const resp_len: usize = @intCast(recv_rc);
        if (resp_len < 12) continue;

        const resp_id = std.mem.readInt(u16, resp[0..2], .big);
        if (resp_id != qid) continue;

        const rcode = resp[3] & 0x0F;
        if (rcode != 0) continue;
        const ancount = std.mem.readInt(u16, resp[6..8], .big);
        if (ancount == 0) continue;

        // Skip question
        var p: usize = 12;
        while (p < resp_len and resp[p] != 0) {
            p += @as(usize, resp[p]) + 1;
        }
        p += 5; // 0 byte + QTYPE (2) + QCLASS (2)

        // Parse answers
        var ans_i: u16 = 0;
        while (ans_i < ancount and p + 10 <= resp_len) : (ans_i += 1) {
            if (resp[p] & 0xC0 == 0xC0) {
                p += 2;
            } else {
                while (p < resp_len and resp[p] != 0) {
                    p += @as(usize, resp[p]) + 1;
                }
                p += 1;
            }
            if (p + 10 > resp_len) break;
            const atype = std.mem.readInt(u16, resp[p..][0..2], .big);
            const rdlen = std.mem.readInt(u16, resp[p + 8 ..][0..2], .big);
            p += 10;
            if (atype == 1 and rdlen == 4 and p + 4 <= resp_len) {
                const result = try std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{
                    resp[p], resp[p + 1], resp[p + 2], resp[p + 3],
                });

                // Cache the resolved result for process lifetime
                const cached_host = std.heap.page_allocator.dupe(u8, host) catch return result;
                const cached_ip = std.heap.page_allocator.dupe(u8, result) catch return result;
                dns_cache.put(std.heap.page_allocator, cached_host, cached_ip) catch {};

                return result;
            }
            p += rdlen;
        }
    }
    return error.UnknownHost;
}

pub fn prepareConnection(client: *std.http.Client, uri: std.Uri) !?*std.http.Client.Connection {
    const raw_host = uri.host orelse return null;
    const host_str = raw_host.percent_encoded;
    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return null;
    const port: u16 = uri.port orelse switch (protocol) {
        .plain => 80,
        .tls => 443,
    };

    var name_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const sni_host = std.Io.net.HostName.init(std.fmt.bufPrint(&name_buf, "{s}", .{host_str}) catch return null) catch return null;

    if (client.connection_pool.findConnection(client.io, .{
        .host = sni_host,
        .port = port,
        .protocol = protocol,
    }) catch null) |existing| return existing;

    const builtin = @import("builtin");
    const need_dns_fallback = builtin.os.tag == .linux and (builtin.target.abi.isAndroid() or !resolvConfExists(client.io));
    if (!need_dns_fallback) return null;

    const ip = resolve(client.allocator, client.io, host_str) catch return null;
    defer client.allocator.free(ip);

    var ip_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const ip_host = std.Io.net.HostName.init(std.fmt.bufPrint(&ip_buf, "{s}", .{ip}) catch return null) catch return null;

    if (protocol == .tls and client.now == null) {
        const now = std.Io.Clock.real.now(client.io);
        var bundle: std.crypto.Certificate.Bundle = .empty;
        defer bundle.deinit(client.allocator);
        bundle.rescan(client.allocator, client.io, now) catch {};
        try client.ca_bundle_lock.lock(client.io);
        defer client.ca_bundle_lock.unlock(client.io);
        client.now = now;
        std.mem.swap(std.crypto.Certificate.Bundle, &client.ca_bundle, &bundle);
    }

    return client.connectTcpOptions(.{
        .host = ip_host,
        .port = port,
        .protocol = protocol,
        .proxied_host = sni_host,
        .proxied_port = port,
    }) catch null;
}

fn resolvConfExists(io: std.Io) bool {
    var f = std.Io.Dir.openFileAbsolute(io, "/etc/resolv.conf", .{}) catch return false;
    f.close(io);
    return true;
}

pub fn request(
    client: *std.http.Client,
    method: std.http.Method,
    uri: std.Uri,
    options: std.http.Client.RequestOptions,
) !std.http.Client.Request {
    var opts = options;
    if (opts.connection == null) {
        opts.connection = prepareConnection(client, uri) catch null;
    }
    return client.request(method, uri, opts);
}

pub fn fetch(
    client: *std.http.Client,
    uri: std.Uri,
    extra_headers: []const std.http.Header,
    response_writer: *std.Io.Writer,
) !std.http.Status {
    var req = try request(client, .GET, uri, .{
        .extra_headers = extra_headers,
    });
    defer req.deinit();

    try req.sendBodiless();

    var redirect_buf: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .deflate, .gzip => try client.allocator.alloc(u8, std.compress.flate.max_window_len),
        .zstd => try client.allocator.alloc(u8, std.compress.zstd.default_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer client.allocator.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    _ = reader.streamRemaining(response_writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |e| return e,
    };

    return response.head.status;
}
