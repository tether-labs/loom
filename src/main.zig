const std = @import("std");
const loompkg = @import("loom");

const resp = "HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\nSUCCESS";
var payload: []u8 = undefined;
var allocator: std.mem.Allocator = undefined;
var local_buffer: [8192]u8 = undefined;
const xsuspend = loompkg.xsuspend;
fn handle(client: *loompkg.Client, msg: []const u8) !void {
    // ✅ GOOD: Capture immediately as local variables
    const my_client = client;
    _ = msg;
    try my_client.chunked(resp);
}

pub fn makePayload(size: usize) ![]u8 {
    const buf = try allocator.alloc(u8, size);
    @memset(buf, 'x');
    return buf;
}

pub fn main() !void {
    allocator = std.heap.page_allocator;

    payload = try allocator.alloc(u8, (resp.len + 10000000));
    @memcpy(payload[0..resp.len], resp);
    @memcpy(payload[resp.len..(resp.len + 10000000)], try makePayload(10000000));

    const config = loompkg.Loom.Config{
        .server_addr = "0.0.0.0",
        .sticky_server = false,
        .server_port = 8080,
        .max = 512,
        .callback = handle,
    };
    var loom: loompkg.Loom = undefined;
    try loom.new(config, &allocator);
    try loom.listen();
}
