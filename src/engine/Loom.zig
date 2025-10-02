const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const system = std.posix.system;
const print = std.debug.print;
const log = std.log.scoped(.tcp_demo);
const Logger = @import("Logger.zig");
const Parsed = std.json.Parsed;
const net = std.net;
const Signature = @import("async/Signature.zig");
const Scheduler = @import("async/Scheduler.zig");
pub const xresume = Scheduler.xresume;
pub const xsuspend = Scheduler.xsuspend;
const ThreadRipper = @import("async/pool/ThreadRipper.zig");
const Client = @import("Client.zig");
const KQueue = @import("KQueue.zig");
const Stack = @import("async/types.zig").Stack;
const Fiber = @import("async/Fiber.zig");
const createFiber = Scheduler.createFiber;
const Io = @import("Io.zig");

// EVFILT_READ
// Monitors for data available to read
// For sockets: triggers when data arrives
// For files: triggers when data is available
// The .data field will contain number of bytes available

// EVFILT_WRITE
// Monitors for write space available
// Triggers when buffer space is available for writing
// .data field contains space available in buffer

// EVFILT_AIO
// For asynchronous I/O operations
// Monitors completion of aio_* functions
// Great for bulk file operations

// EVFILT_VNODE
// Monitors changes to files and directories
// Can detect: delete, write, extend, attrib, link, rename
// Commonly used for config file monitoring

// EVFILT_PROC
// Monitors process events
// Can detect: exit, fork, exec, signal
// Useful for process supervision

// EVFILT_SIGNAL
// Monitors for Unix signals
// Alternative to traditional signal handlers
// More flexible than signal()

// EVFILT_TIMER
// Creates a timer event
// Can be one-shot or periodic
// More efficient than multiple individual timers

// EVFILT_USER
// User-triggered events
// Allows triggering events from userspace
// Useful for inter-thread communication

// EV_ADD
// Add an event to kqueue monitoring
// If it exists, modify it
// Most common flag you'll use

// EV_DELETE
// Remove event from monitoring
// Stops watching for this event
// Use when cleaning up

// EV_ENABLE
// Enable an event that was disabled
// Event can now trigger
// Paired with EV_DISABLE

// EV_DISABLE
// Temporarily disable event
// Event won't trigger until enabled
// Good for temporary suspensions

// EV_ONESHOT
// Only trigger once
// Automatically removed after triggering
// Good for one-time notifications

// EV_CLEAR
// Clear event state after triggering
// Prevents edge-triggered notification pileup
// Important for high-throughput scenarios

// EV_EOF
// End of file condition
// Set by system when EOF detected
// Useful for connection handling

// EV_ERROR
// Error condition
// Set by system when error occurs
// Check errno for details

// 1 minute
const READ_TIMEOUT_MS = 60_000;
// const READ_TIMEOUT_MS = 0;

const ClientList = Client.ClientList;
const ClientNode = Client.ClientNode;
pub var logger: Logger = undefined;

pub const Loom = @This();
arena: *Allocator = undefined,
config: Config = undefined,
// Max connections
max: usize = undefined,

listener: *posix.socket_t = undefined,

// Event Loop
kqueue: KQueue = undefined,
io: Io = undefined,
stacks: []Stack = undefined,
current_fiber: *Fiber = undefined,
fibers: []*Fiber = undefined,

// The number of clients we currently have connected
connected: u32 = undefined,

read_timeout_list: ClientList = undefined,

// for creating client
client_pool: std.heap.MemoryPool(Client) = undefined,
// for creating nodes for our read_timeout list
client_node_pool: std.heap.MemoryPool(ClientNode) = undefined,
scheduler: Scheduler = undefined,
stack: Stack = undefined,
max_body_size: usize,

pub const Config = struct {
    server_addr: []const u8 = "0.0.0.0",
    server_port: u16 = 8080,
    sticky_server: bool = false,
    max: usize = 256,
    max_body_size: usize = 4 * 1024 * 1024,
    max_read_size: usize = 2097152,
    callback: *const fn (*Client, []const u8) anyerror!void,
};

const resp = "HTTP/1.1 200 OK\r\nDate: Tue, 19 Aug 2025 18:37:36 GMT\r\nContent-Length: 7\r\nContent-Type: text/plain charset=utf-8\r\n\r\nSUCCESS";
// _ = try posix.write(client.socket, resp);
fn handle(client: *Client, _: []const u8) !void {
    // try callback(client, data);
    _ = try posix.write(client.socket, resp);
    xsuspend();
}

fn handleCTX() !void {
    while (true) {
        try callback(handler_context.client, handler_context.msg);
        xsuspend();
    }
}

/// This is the Cors struct default set to null
var callback: *const fn (*Client, []const u8) anyerror!void = undefined;
const HandlerContext = struct {
    msg: []const u8 = "",
    client: *Client = undefined,
};
var handler_context: HandlerContext = .{};

pub fn new(target: *Loom, config: Config, arena: *Allocator) !void {
    var scheduler: Scheduler = undefined;
    try scheduler.init(arena.*);

    var kqueue = try KQueue.init();
    errdefer kqueue.deinit();

    var io: Io = undefined;
    io.init(arena, &kqueue);

    const stacks = try arena.alloc(Stack, config.max);
    const fibers = try arena.alloc(*Fiber, config.max);
    for (0..config.max) |i| {
        stacks[i] = try scheduler.stackAlloc(1024 * 1024 * 2);
        fibers[i] = try createFiber(handleCTX, .{}, stacks[i]);
    }

    // const stack = try scheduler.stackAlloc(1024 * 1024 * 2);
    // const fiber = try createFiber(handleCTX, .{}, stack);
    logger.init();
    target.* = Loom{
        .config = config,
        .arena = arena,
        .max = config.max,
        .connected = 0,
        .read_timeout_list = .{},
        .client_pool = std.heap.MemoryPool(Client).init(arena.*),
        .client_node_pool = std.heap.MemoryPool(ClientNode).init(arena.*),
        .scheduler = scheduler,
        .kqueue = kqueue,
        .stacks = stacks,
        .io = io,
        .max_body_size = config.max_body_size,
        .fibers = fibers,
        // .current_fiber = fiber,
    };

    Client.writer_buf = try arena.alloc(u8, config.max_body_size);
    Client.reader_buf = try arena.alloc(u8, config.max_read_size);
    callback = config.callback;
    errdefer arena.free(Client.writer_buf);
}

pub fn deinit(self: *Loom) void {
    self.kqueue.deinit();
    self.client_pool.deinit();
    self.client_node_pool.deinit();
    self.arena.free(self.stack);
    self.arena.free(Client.writer_buf);
}

pub fn createListener(loom: *Loom) !c_int {
    // const self_addr = try net.Address.resolveIp(loom.config.server_addr, loom.config.server_port);
    const self_addr = try net.Address.resolveIp(loom.config.server_addr, loom.config.server_port);

    // 1. Create non-blocking socket
    const tpe: u32 = posix.SOCK.STREAM | posix.SOCK.NONBLOCK;
    const listener = try posix.socket(self_addr.any.family, tpe, posix.IPPROTO.TCP);

    // 2. Set REUSEPORT FIRST (MUST BE BEFORE BIND)
    const reuse = std.mem.toBytes(@as(c_int, 1));
    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEPORT, &reuse);
    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &reuse);

    // 3. Bind and listen
    try posix.bind(listener, &self_addr.any, self_addr.getOsSockLen());
    try posix.listen(listener, 4096);

    // 4. Add to THIS THREAD'S kqueue (not a shared one)
    try loom.kqueue.addListener(listener);

    // 5. Force flush kqueue changes immediately
    try loom.kqueue.flushChanges();

    return listener;
}

/// This function calls listen on the Loom instance.
///
/// # Returns:
/// !void.
pub fn listen(loom: *Loom) !void {
    const listener = loom.createListener() catch return;
    // Verify unique resources
    // std.debug.assert(loom.kqueue.kfd == kqueue.kfd);
    try run(loom, listener);
}

fn run(
    loom: *Loom,
    listener: posix.socket_t,
) !void {
    while (true) {
        // const next_timeout = loom.enforceTimeout();
        const ready_events = loom.readEvents(-1) catch return;
        for (ready_events) |ready| {
            // ready is type kevent
            // udata is the client conn value
            switch (ready.udata) {
                0 => {
                    while (true) {
                        loom.acceptConn(listener) catch |err| switch (err) {
                            error.WouldBlock => break, // No more connections waiting, break inner loop
                            else => |e| log.err("accept error: {}", .{e}),
                        };
                    }
                },
                else => |nptr| {
                    const client: *Client = @ptrFromInt(nptr);
                    const filter = ready.filter;

                    // Here we read in the client data
                    // we check the filter state
                    if (filter == system.EVFILT.READ) {
                        while (true) {
                            const msg = client.readMessage() catch |err| {
                                switch (err) {
                                    error.WouldBlock => {
                                        break;
                                    },
                                    else => {
                                        loom.closeClient(client);
                                        break;
                                    },
                                }
                            };

                            // client.read_timeout = std.time.milliTimestamp() + READ_TIMEOUT_MS;
                            client.fiber = loom.fibers[loom.connected - 1];
                            handler_context.client = client;
                            handler_context.msg = msg;
                            xresume(client.fiber.?);
                        }
                    } else if (filter == system.EVFILT.WRITE) {
                        // If we couldn't write for some reason initially then
                        // when we receive a write event we write to the client
                        // _ = client.writeMessage() catch {
                        loom.closeClient(client);
                        // };
                    }
                },
            }
        }
    }
}

pub fn enforceTimeout(self: *Loom) i32 {
    const now = std.time.milliTimestamp();
    var node = self.read_timeout_list.first;
    while (node) |n| {
        const client = n.data;
        const diff = client.read_timeout - now;
        if (diff > 0) {
            // this client's timeout is the first one that's in the
            // future, so we now know the maximum time we can block on
            // poll before having to call enforceTimeout again
            return @intCast(diff);
        }

        // This client's timeout is in the past. Close the socket
        // Ideally, we'd call server.removeClient() and just remove the
        // client directly. But within this method, we don't know the
        // client_polls index. When we move to epoll / kqueue, this problem
        // will go away, since we won't need to maintain polls and client_polls
        // in sync by index.
        posix.shutdown(client.socket, .recv) catch {};
        node = n.next;
    } else {
        // We have no client that times out in the future (if we did
        // we would have hit the return above).
        return -1;
    }
}

pub fn acceptConn(self: *Loom, listener: posix.socket_t) !void {
    var address: net.Address = undefined;
    var address_len: posix.socklen_t = @sizeOf(net.Address);
    // const space = self.max - self.connected;
    if (self.connected < self.max) {
        const socket = posix.accept(listener, &address.any, &address_len, posix.SOCK.NONBLOCK) catch |err| switch (err) {
            error.WouldBlock => return error.WouldBlock,
            else => return err,
        };

        const client: *Client = try self.client_pool.create();
        errdefer self.client_pool.destroy(client);
        client.* = Client.init(self.arena.*, socket, address, &self.kqueue) catch |err| {
            posix.close(socket);
            log.err("failed to initialize client: {}", .{err});
            return err;
        };
        errdefer client.deinit(self.arena.*);

        client.read_timeout = std.time.milliTimestamp() + READ_TIMEOUT_MS;
        client.read_timeout_node = try self.client_node_pool.create();
        errdefer self.client_node_pool.destroy(client.read_timeout_node);

        client.read_timeout_node.* = ClientNode{
            .node = .{},
            .data = client,
        };

        // self.read_timeout_list.append(&client.read_timeout_node.node);
        try self.kqueue.newClient(client);
        self.connected += 1;
    } else {
        print("We Ran out of space\n", .{});
        // we've run out of space, stop monitoring the listening socket
        try self.kqueue.removeListener(listener);
    }
}

pub fn readEvents(loom: *Loom, next_timeout: i32) ![]system.Kevent {
    return try loom.kqueue.wait(next_timeout);
}

pub fn closeClient(self: *Loom, client: *Client) void {
    self.read_timeout_list.remove(&client.read_timeout_node.node);
    self.client_node_pool.destroy(client.read_timeout_node);
    client.deinit(self.arena.*);
    posix.close(client.socket);
    self.client_pool.destroy(client);
    self.connected -= 1;
}
