const std = @import("std");
const loompkg = @import("loom");

const resp = "HTTP/1.1 200 OK\r\nContent-Length: 10000000\r\n\r\n";
const simple_resp = "HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\nSUCCESS";
var payload: []u8 = undefined;
var allocator: std.mem.Allocator = undefined;
var local_buffer: [8192]u8 = undefined;
const xsuspend = loompkg.xsuspend;
fn handle(client: *loompkg.Client, msg: []const u8) !void {
    // ✅ GOOD: Capture immediately as local variables
    const my_client = client;
    _ = msg;
    try my_client.chunked(payload);
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

    // var file = try std.fs.cwd().openFile("./index.html", .{ .mode = .read_only });
    // const stat = try file.stat();
    // defer file.close();
    // const index = file.readToEndAlloc(allocator, stat.size) catch unreachable;
    // const httpHead =
    //     "HTTP/1.1 200 OK \r\n" ++
    //     "Connection: close\r\n" ++
    //     "Access-Control-Allow-Origin: *\r\n" ++
    //     "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" ++
    //     "Access-Control-Allow-Headers: Content-Type, Authorization\r\n" ++
    //     // "Cache-Control: public, max-age=31536000, immutable\r\n" ++
    //     "Content-Type: {s}\r\n" ++
    //     "Content-Length: {}\r\n" ++
    //     "\r\n" ++
    //     "{s}";
    // const response = try std.fmt.allocPrint(allocator, httpHead, .{ "text/html", index.len, index });
    // defer allocator.free(response);
    // payload = response;

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
