const std = @import("std");
const http = std.http;
const Connection = std.http.Client.Connection;
const posix = std.posix;
const Uri = std.Uri;
const Allocator = std.mem.Allocator;
const system = std.posix.system;
const KQueue = @import("KQueue.zig");
const Scheduler = @import("async/Scheduler.zig");
const Fiber = @import("async/Fiber.zig");
const Kit = @import("Kit.zig");
const createFiber = Scheduler.createFiber;
const xresume = Scheduler.xresume;
const xsuspend = Scheduler.xsuspend;
const helpers = @import("helpers.zig");
const Ctx_pm = @import("helpers.zig").Ctx_pm;

var scheduler: Scheduler = undefined;
var current_fiber: *Fiber = undefined;

const Io = @This();
allocator: *Allocator,
kqueue: *KQueue,

pub fn init(io: *Io, allocator: *Allocator, kqueue: *KQueue) void {
    io.* = .{
        .allocator = allocator,
        .kqueue = kqueue,
    };
}

fn validateUri(uri: Uri, arena: Allocator) !struct { Connection.Protocol, Uri } {
    const protocol_map = std.StaticStringMap(Connection.Protocol).initComptime(.{
        .{ "http", .plain },
        .{ "ws", .plain },
        .{ "https", .tls },
        .{ "wss", .tls },
    });
    const protocol = protocol_map.get(uri.scheme) orelse return error.UnsupportedUriScheme;
    var valid_uri = uri;
    // The host is always going to be needed as a raw string for hostname resolution anyway.
    valid_uri.host = .{
        .raw = try (uri.host orelse return error.UriMissingHost).toRawMaybeAlloc(arena),
    };
    return .{ protocol, valid_uri };
}

fn uriPort(uri: Uri, protocol: Connection.Protocol) u16 {
    return uri.port orelse switch (protocol) {
        .plain => 80,
        .tls => 443,
    };
}

pub fn addConnEvents(io: *Io, client_fd: posix.socket_t) !void {
    try io.kqueue.addEventRaw(.{
        .ident = @intCast(client_fd),
        .flags = posix.system.EV.ADD,
        .filter = posix.system.EVFILT.WRITE, // Wait for writable = connected
        .fflags = 0,
        .data = 0,
        .udata = @intFromPtr(current_fiber),
    });

    try io.kqueue.addEventRaw(.{
        .ident = @intCast(client_fd),
        .flags = posix.system.EV.ADD | posix.system.EV.DISABLE,
        .filter = posix.system.EVFILT.READ,
        .fflags = 0,
        .data = 0,
        .udata = @intFromPtr(current_fiber),
    });
}

pub fn readMode(io: *Io, client_fd: posix.socket_t) !void {
    try io.kqueue.addEventRaw(.{
        .ident = @intCast(client_fd),
        .flags = posix.system.EV.DISABLE,
        .filter = posix.system.EVFILT.WRITE, // Wait for writable = connected
        .fflags = 0,
        .data = 0,
        .udata = @intFromPtr(current_fiber),
    });

    try io.kqueue.addEventRaw(.{
        .ident = @intCast(client_fd),
        .flags = posix.system.EV.ENABLE,
        .filter = posix.system.EVFILT.READ,
        .fflags = 0,
        .data = 0,
        .udata = @intFromPtr(current_fiber),
    });
}

pub fn httpConnect(io: *Io, url: []const u8, http_req: Kit.HttpReq) !helpers.HTTPHeader {
    const uri = try std.Uri.parse(url);
    const protocol, const valid_uri = try validateUri(uri, io.allocator.*);
    const addresses = std.net.getAddressList(io.allocator.*, valid_uri.host.?.raw, uriPort(valid_uri, protocol)) catch |err| {
        std.debug.print("Failed to get address list: {}\n", .{err});
        return err;
    };
    defer addresses.deinit();
    var address = addresses.addrs[0];
    const tpe: u32 = posix.SOCK.STREAM | posix.SOCK.NONBLOCK;
    const client_fd = try posix.socket(posix.AF.INET, tpe, posix.IPPROTO.TCP);
    var option_value: i32 = 1; // Enable the option
    const option_value_bytes = std.mem.asBytes(&option_value);
    try posix.setsockopt(client_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, option_value_bytes);
    posix.connect(client_fd, &address.any, address.getOsSockLen()) catch |err| {
        switch (err) {
            error.WouldBlock => {
                // This is expected! Add to event loop and suspend
                try addConnEvents(io, client_fd);

                // Suspend until connection is ready
                xsuspend();

                // When resumed, check if connection succeeded
                var sock_err: c_int = 0;
                const err_option_value_bytes = std.mem.asBytes(&sock_err);
                posix.getsockopt(client_fd, posix.SOL.SOCKET, posix.SO.ERROR, err_option_value_bytes) catch |gso_err| {
                    std.debug.print("getsockopt failed: {}\n", .{gso_err});
                    return gso_err;
                };

                if (sock_err != 0) {
                    std.debug.print("Connection failed with errno: {}\n", .{sock_err});
                    return error.ConnectionFailed;
                }

                // Additional check: try to get peer address
                var peer_addr: posix.sockaddr = undefined;
                var peer_len: posix.socklen_t = @sizeOf(posix.sockaddr);
                posix.getpeername(client_fd, &peer_addr, &peer_len) catch |peer_err| {
                    std.debug.print("Not connected - getpeername failed: {}\n", .{peer_err});
                    return error.NotConnected;
                };

                std.debug.print("Connected successfully!\n", .{});
            },
            error.ConnectionRefused => {
                std.debug.print("Connection refused\n", .{});
                return err;
            },
            else => {
                std.debug.print("Connect error: {}\n", .{err});
                return err;
            },
        }
    };

    const request = Kit.stringifyHttpReq(url, http_req);
    _ = posix.write(client_fd, request) catch |err| {
        std.debug.print("Failed to write request: {}\n", .{err});
        if (err == error.WouldBlock) {
            // This is expected! Add to event loop and suspend
            xsuspend();
        }
    };
    try io.readMode(client_fd);
    xsuspend();

    // 3. Read response (also needs non-blocking handling)
    var response_buffer: [4096]u8 = undefined;
    const bytes_read = posix.read(client_fd, &response_buffer) catch |err| {
        std.debug.print("Read error: {}\n", .{err});
        return err;
    };

    var ctx_pm = Ctx_pm{};
    const http_header = helpers.parseHeaders(response_buffer[0..bytes_read], &ctx_pm);
    posix.close(client_fd);
    return http_header.*;
}

fn processConnection(io: *Io) !void {
    const http_resp = try io.httpConnect("http://httpbin.org/get", .{
        .method = .GET,
        .headers = .{
            .accept = "application/json",
            .user_agent = "ZigClient/1.0",
        },
    });
    std.debug.print("Response body: {s}\n", .{http_resp.body});
    xsuspend();
}

test "conn" {
    var io: Io = undefined;
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    var allocator = debug_allocator.allocator();
    defer if (debug_allocator.deinit() != .ok) @panic("DebugAllocator leak");
    try scheduler.init(allocator);
    var kqueue = try KQueue.init();
    io.init(&allocator, &kqueue);

    const stack = try scheduler.stackAlloc(1024 * 1024);
    defer allocator.free(stack);
    current_fiber = try createFiber(processConnection, .{&io}, stack);
    xresume(current_fiber);

    while (true) {
        const read_events = try kqueue.wait(-1);
        std.debug.print("Awaiting events: {any}\n", .{read_events.len});
        for (read_events) |event| {
            switch (event.filter) {
                system.EVFILT.READ => {
                    xresume(current_fiber);
                    std.debug.print("Read event\n", .{});
                },
                system.EVFILT.WRITE => {
                    xresume(current_fiber);
                    std.debug.print("Write event\n", .{});
                },
                else => {
                    std.debug.print("Unknown event\n", .{});
                },
            }
        }
    }
}
