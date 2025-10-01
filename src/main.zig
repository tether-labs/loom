const std = @import("std");
const lib = @import("loom");

// fn handle(client: *lib.Client, msg: []const u8) !void {
//     std.debug.print("Message: {s}\n", .{msg});
// }

pub fn main() !void {
    var allocator = std.heap.page_allocator;
    const config = lib.Loom.Config{
        .server_addr = "0.0.0.0",
        .server_port = 8080,
        .sticky_server = false,
        .max = 256,
        .max_body_size = 4 * 1024 * 1024,
        .callback = undefined,
    };
    var loom: lib.Loom = undefined;
    try loom.new(config, &allocator, 0);
    try loom.listen();
}
