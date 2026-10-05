const std = @import("std");
const dns = @import("dns.zig");

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

    const ip = dns.resolve(client.allocator, client.io, host_str) catch return null;
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
