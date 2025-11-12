const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const KQueue = @import("KQueue.zig");
const Loom = @import("Loom.zig");
const Fiber = @import("async/Fiber.zig");
const Stack = @import("async/types.zig").Stack;
const Scheduler = @import("async/Scheduler.zig");
const xsuspend = Scheduler.xsuspend;

pub const ClientList = std.DoublyLinkedList;
pub const ClientNode = struct {
    node: ClientList.Node,
    data: *Client,
};

pub const Client = @This();
kqueue: *KQueue,

socket: posix.socket_t,
address: std.net.Address,
fiber: ?*Fiber = null,
fiber_index: usize = 0,
stack: ?Stack = undefined,

// Used to read length-prefixed messages
msg: []const u8,

// Used to write messages
writer: Writer,
reader: Reader,
response: []const u8,

// absolute time, in millisecond, when this client should timeout if
// a message isn't received
read_timeout: i64,

// Node containing this client in the server's read_timeout_list
read_timeout_node: *ClientNode,

pub fn init(_: Allocator, socket: posix.socket_t, address: std.net.Address, kqueue: *KQueue) !Client {

    // const write_buf = try arena.alloc(u8, 4096);
    // errdefer arena.free(write_buf);

    return .{
        .kqueue = kqueue,
        .socket = socket,
        .address = address,
        .msg = "",
        .writer = .{},
        .reader = .{},
        .response = "",
        .read_timeout = 0, // let the server set this
        .read_timeout_node = undefined, // hack/ugly, let the server set this when init returns
    };
}

pub fn deinit(_: *const Client, _: Allocator) void {
    // self.writer.deinit(arena);
}

fn findEndOfHeaders(buffer: []const u8) ?usize {
    // Need at least 4 bytes for \r\n\r\n
    if (buffer.len < 4) return null;

    // Use a sliding window of 4 bytes
    var i: usize = 0;
    while (i <= buffer.len - 4) : (i += 1) {
        // Check all 4 bytes at once
        if (buffer[i] == '\r' and
            buffer[i + 1] == '\n' and
            buffer[i + 2] == '\r' and
            buffer[i + 3] == '\n')
        {
            return i + 4; // Return position after the sequence
        }
    }
    return null;
}

pub fn findCRLFCRLF(payload: []const u8) ?usize {
    if (payload.len < 4) return null;

    if (payload.len >= 32) {
        const V = @Vector(32, u8);
        const cr_pattern: V = @splat('\r');
        var i: usize = 0;

        while (i + 32 <= payload.len) : (i += 32) {
            const chunk: V = payload[i..][0..32].*;
            const cr_matches = chunk == cr_pattern;
            const cr_mask: u32 = @bitCast(cr_matches);

            if (cr_mask != 0) {
                var mask = cr_mask;
                while (mask != 0) {
                    const pos = i + @ctz(mask);
                    if (pos + 3 < payload.len and
                        payload[pos + 1] == '\n' and
                        payload[pos + 2] == '\r' and
                        payload[pos + 3] == '\n')
                    {
                        return pos;
                    }
                    mask &= mask - 1;
                }
            }
        }

        // Check remaining bytes after last 32-byte chunk
        i -= 3; // Ensure we check overlapping with the last chunk's end
        while (i < payload.len - 3) : (i += 1) {
            if (payload[i] == '\r' and
                payload[i + 1] == '\n' and
                payload[i + 2] == '\r' and
                payload[i + 3] == '\n')
            {
                return i;
            }
        }
        return null;
    }

    // Non-SIMD path for small payloads
    var i: usize = 0;
    while (i <= payload.len - 4) : (i += 1) {
        if (payload[i] == '\r' and
            payload[i + 1] == '\n' and
            payload[i + 2] == '\r' and
            payload[i + 3] == '\n')
        {
            return i;
        }
    }
    return null;
}

// pub var reader_buf: [2097152]u8 = [_]u8{0} ** 2097152;
pub var reader_buf: []u8 = undefined;
pub fn readMessage(self: *Client) ![]const u8 {
    return self.reader.readMessage(self.socket) catch |err| {
        switch (err) {
            error.WouldBlock => {
                return error.WouldBlock;
            },
            error.BrokenPipe, error.ConnectionResetByPeer => {
                return err;
            },
            else => return err,
        }
    };

    // const rv = try posix.read(self.socket, reader_buf);
    // if (rv == 0) {
    //     return error.Closed;
    // }
    //
    // // var end = buf[0..rv].len;
    // // std.debug.print("{s}\n", .{buf[0..rv]});
    // // if (buf[end - 1] != 10) {
    // //     // std.debug.print("H\n", .{});
    // //     end = findCRLFCRLF(buf[0..rv]).?;
    // //     // std.debug.print("{any}\n", .{end});
    // // }
    //
    // return reader_buf[0..rv];
}

pub fn writeMessage(self: *Client) !void {
    self.writer.writeMessage(self.socket) catch |err| {
        switch (err) {
            error.WouldBlock => {
                // Arm for WRITE notifications
                // std.debug.print("ARMMing WRITE\n", .{});
                try self.kqueue.writeMode(self);
                xsuspend();
                return;
            },
            error.BrokenPipe, error.ConnectionResetByPeer => {
                return err;
            },
            else => return err,
        }
    };
    return; // This is the success (void) case
}

pub fn chunked(self: *Client, payload: []const u8) !void {
    var pos: usize = 0;
    while (pos < payload.len) {
        // Calculate how much we can fit in the buffer
        const remaining = payload.len - pos;
        const buffer_capacity = self.writer.buf.len;
        const chunk_size = @min(remaining, buffer_capacity);

        // Fill the write buffer with the chunk
        self.fillWriteBuffer(payload[pos .. pos + chunk_size]) catch {
            // std.debug.print("Fill write buffer error: {any}\n", .{err});
        };

        // Keep trying to write this chunk until complete
        while (true) {
            self.writeMessage() catch |err| {
                return err;
            };
            // Write completed, move to next chunk
            break;
        }
        pos += chunk_size;
    }
}

pub fn fillWriteBuffer(self: *Client, msg: []const u8) !void {
    self.writer.fillWriteBuffer(msg) catch |err| {
        try Loom.logger.err("Fill write buffer {any}", .{err}, @src());
        return err;
    };
}

const Reader = struct {
    buf: [8192]u8 = undefined,
    pos: usize = 0,
    offset: usize = 0, // How much we've sent from the buffer

    pub fn init() !Reader {
        return .{
            .pos = 0,
            .offset = 0,
        };
    }

    pub fn deinit(_: *const Reader, _: Allocator) void {
        // arena.free(self.buf);
    }

    pub fn readMessage(self: *Reader, socket: posix.socket_t) ![]u8 {
        // Try to write remaining data
        const rv = posix.read(socket, self.buf[0..]) catch |err| {
            switch (err) {
                error.WouldBlock => return error.WouldBlock,
                else => return err,
            }
        };
        self.pos = rv;

        if (rv == 0) {
            return error.Closed;
        }

        return self.buf[0..self.pos];
    }
};

pub var writer_buf: []u8 = undefined;

const Writer = struct {
    buf: [65536]u8 = undefined,
    pos: usize = 0, // Current write position in buffer
    offset: usize = 0, // How much we've sent from the buffer

    pub fn init(_: Allocator, _: usize) !Writer {
        return .{
            .pos = 0,
            .offset = 0,
        };
    }

    pub fn deinit(_: *const Writer, _: Allocator) void {}

    pub fn fillWriteBuffer(self: *Writer, msg: []const u8) !void {
        // Check if we have space (optional safety check)
        if (self.pos + msg.len > self.buf.len) {
            return error.BufferFull;
        }

        // Copy data into buffer at current position
        @memcpy(self.buf[self.pos..][0..msg.len], msg);
        self.pos += msg.len;
    }

    pub fn writeMessage(self: *Writer, socket: posix.socket_t) !void {
        // Nothing to write
        if (self.offset >= self.pos) {
            return;
        }

        // Try to write remaining data
        const wv = posix.write(socket, self.buf[self.offset..self.pos]) catch |err| {
            switch (err) {
                error.WouldBlock => return error.WouldBlock,
                else => return err,
            }
        };

        if (wv == 0) {
            return error.Closed;
        }

        // Update how much we've sent
        self.offset += wv;

        // Check if we've sent everything
        if (self.offset < self.pos) {
            // Still have data to send
            return error.WouldBlock;
        } else {
            // All data sent, reset for next message
            self.pos = 0;
            self.offset = 0;
        }
    }

    // Helper to check if write is complete
    pub fn isComplete(self: *const Writer) bool {
        return self.offset >= self.pos;
    }

    // Helper to reset without completing a write
    pub fn reset(self: *Writer) void {
        self.pos = 0;
        self.offset = 0;
    }
};
// const Writer = struct {
//     buf: [8192]u8 = undefined, // Buffer to write to
//     pos: usize = 0,
//     start: usize = 0,
//     offset: usize = 0,
//
//     pub fn init(_: Allocator, _: usize) !Writer {
//         return .{
//             // .buf = writer_buf,
//             .pos = 0,
//             .start = 0,
//             .offset = 0,
//         };
//     }
//
//     pub fn deinit(_: *const Writer, _: Allocator) void {
//         // arena.free(self.buf);
//     }
//
//     pub fn fillWriteBuffer(self: *Writer, msg: []const u8) !void {
//         self.pos += msg.len;
//         @memcpy(self.buf[self.start..self.pos], msg);
//         self.start += msg.len;
//     }
//
//     pub fn writeMessage(self: *Writer, socket: posix.socket_t) !void {
//         var buf = self.buf;
//         const end = self.pos;
//         const start = self.start;
//         std.debug.assert(end >= start);
//         const wv = posix.write(socket, buf[self.offset..end]) catch |err| {
//             switch (err) {
//                 error.WouldBlock => return error.WouldBlock,
//                 else => return err,
//             }
//         };
//         if (wv == 0) {
//             return error.Closed;
//         }
//
//         // This means we havent written all the data yet
//         self.offset += wv;
//         if (end > self.offset) {
//             return error.WouldBlock;
//         } else {
//             self.offset = 0;
//             self.pos = 0;
//             self.start = 0;
//         }
//     }
// };
