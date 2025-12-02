// const std = @import("std");
// const print = std.debug.print;
// const posix = std.posix;
const Client = @import("Client.zig");
// const net = std.net;
// // WebSocket opcodes (RFC 6455 Section 5.2)
// pub const Opcode = enum(u4) {
//     Continuation = 0x0,
//     Text = 0x1,
//     Binary = 0x2,
//     Close = 0x8,
//     Ping = 0x9,
//     Pong = 0xA,
// };
//
// // Create test frame bytes
// const frame = [_]u8{
//     0x81, // First byte: FIN=1, RSV1-3=0, Opcode=1 (text)
//     0x85, // Second byte: Mask=1, Payload len=5
//     0x37, 0xfa, 0x21, 0x3d, // Masking key
//     0x7f, 0x9f, 0x4d, 0x51,
//     0x58, // Masked "hello" payload
// };
//
// // 10000001  (129)
// // 10000000  (0x80)
// // --------  (AND)
// // 10000000  = 128
//
// pub fn readFrame(_: *Client, arena: *std.mem.Allocator, msg: []const u8) !void {
//     var offset: usize = 0;
//
//     // --- Header (2 bytes) ---
//     const header = msg[offset .. offset + 2];
//     offset += 2;
//
//     const first = header[0];
//     const second = header[1];
//
//     const fin = (first & 0x80) != 0;
//     const opcode: Opcode = @enumFromInt(first & 0x0F);
//     const masked = (second & 0x80) != 0;
//     var payload_len: u64 = (second & 0x7F);
//
//     // --- Extended lengths ---
//     if (payload_len == 126) {
//         const len_bytes = msg[offset .. offset + 2];
//         offset += 2;
//         payload_len = std.mem.readVarInt(u16, len_bytes, .big);
//     } else if (payload_len == 127) {
//         const len_bytes = msg[offset .. offset + 8];
//         offset += 8;
//         payload_len = std.mem.readVarInt(u64, len_bytes, .big);
//     }
//
//     // --- Masking key ---
//     var mask_key: []const u8 = &[_]u8{};
//     if (masked) {
//         mask_key = msg[offset .. offset + 4];
//         offset += 4;
//     }
//
//     // --- Payload ---
//     const payload = msg[offset .. offset + payload_len];
//
//     // --- Unmask if needed ---
//     var unmasked = try arena.alloc(u8, payload_len);
//     if (masked) {
//         for (payload, 0..) |b, i| {
//             unmasked[i] = b ^ mask_key[i % 4];
//         }
//     } else {
//         @memcpy(unmasked, payload);
//     }
//
//     std.debug.print(
//         "FIN={any} OPCODE={any} payload=\"{s}\"\n",
//         .{ fin, opcode, unmasked },
//     );
// }
//
// pub fn sendFrame(client: *Client, opcode: Opcode, payload: []const u8) !void {
//     var header: [10]u8 = undefined;
//     var i: usize = 0;
//
//     header[0] = @intFromEnum(opcode); // FIN bit set
//     header[0] = header[0] | 0x80;
//     i += 1;
//
//     if (payload.len <= 125) {
//         header[i] = @intCast(payload.len);
//         i += 1;
//     } else if (payload.len <= 65535) {
//         header[i] = 126;
//         i += 1;
//         var len_bytes: [2]u8 = undefined;
//         std.mem.writeInt(u16, &len_bytes, @intCast(payload.len), .big);
//         @memcpy(header[i .. i + 2], &len_bytes);
//         i += 2;
//     } else {
//         header[i] = 127;
//         i += 1;
//         var len_bytes: [8]u8 = undefined;
//         std.mem.writeInt(u64, &len_bytes, @intCast(payload.len), .big);
//         @memcpy(header[i .. i + 8], &len_bytes);
//         i += 8;
//     }
//
//     try client.fillWriteBuffer(header[0..i]);
//     try client.fillWriteBuffer(payload);
//     _ = try client.writeMessage();
// }

const std = @import("std");
const print = std.debug.print;
const Allocator = std.mem.Allocator;

pub const Opcode = enum(u4) {
    Continuation = 0x0,
    Text = 0x1,
    Binary = 0x2,
    Close = 0x8,
    Ping = 0x9,
    Pong = 0xA,
    _,
};

pub const WsError = error{
    IncompleteFrame,
    ProtocolError,
    PayloadTooLarge,
    InvalidOpcode,
    InvalidUtf8,
    Unsupported,
};

pub const Message = union(enum) {
    Text: []u8,
    Binary: []u8,
    Ping: []u8,
    Pong: []u8,
    Close: struct { code: u16, reason: []u8 },
};

pub const Websocket = @This();
client: *Client,
parser: Parser,

pub fn init(client: *Client, allocator: *Allocator, body_size: usize) !Websocket {
    return Websocket{
        .client = client,
        .parser = try Parser.init(allocator, 4096, body_size),
    };
}

/// Incremental parser that can be fed chunks of bytes and will produce complete frames/messages.
/// It does not read from the socket itself; you supply bytes read.
pub const Parser = struct {
    buf: []u8, // window into internal buffer
    storage: []u8, // owned storage backing buf
    write_pos: usize, // how many bytes in storage
    max_message_size: usize,
    allocator: *Allocator,

    pub fn init(allocator: *Allocator, capacity: usize, max_message_size: usize) !Parser {
        var storage = try allocator.alloc(u8, capacity);
        return Parser{
            .buf = storage[0..0],
            .storage = storage,
            .write_pos = 0,
            .max_message_size = max_message_size,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.allocator.free(self.storage);
        self.buf = &[_]u8{};
        self.storage = &[_]u8{};
        self.write_pos = 0;
    }

    pub fn reset(self: *Parser) void {
        self.write_pos = 0;
        self.buf = self.storage[0..self.write_pos];
    }

    /// feed more bytes (from socket) into the parser buffer
    pub fn feed(self: *Parser, chunk: []const u8) !void {
        const cap = self.storage.len;
        if (self.write_pos + chunk.len > cap) {
            return WsError.PayloadTooLarge;
        }
        @memcpy(self.storage[self.write_pos .. self.write_pos + chunk.len], chunk);
        self.write_pos += chunk.len;
        self.buf = self.storage[0..self.write_pos];
    }

    /// Try to parse a single frame/message. Returns WsError.IncompleteFrame if more bytes required.
    pub fn nextMessage(self: *Parser, validate_utf8: bool) !Message {
        var offset: usize = 0;
        // Need at least 2 bytes for header
        if (self.write_pos < 2) return WsError.IncompleteFrame;

        const first = self.buf[0];
        const second = self.buf[1];

        const fin = (first & 0x80) != 0;
        const rsv = (first & 0x70) != 0;
        if (rsv) return WsError.ProtocolError;

        const opcode_val = first & 0x0F;
        const masked = (second & 0x80) != 0;
        var payload_len_small: u64 = (second & 0x7F);

        offset = 2;

        // Extended lengths
        if (payload_len_small == 126) {
            if (self.write_pos < offset + 2) return WsError.IncompleteFrame;
            payload_len_small = 0;
            for (0..2) |i| {
                payload_len_small = (payload_len_small << 8) | @as(u8, @intCast(self.buf[offset + i]));
            }
            offset += 2;
        } else if (payload_len_small == 127) {
            if (self.write_pos < offset + 8) return WsError.IncompleteFrame;
            payload_len_small = 0;
            for (0..8) |i| {
                payload_len_small = (payload_len_small << 8) | @as(u8, @intCast(self.buf[offset + i]));
            }
            offset += 8;
        }

        // Masking key
        var mask_key: [4]u8 = undefined;
        if (masked) {
            if (self.write_pos < offset + 4) return WsError.IncompleteFrame;
            for (0..4) |i| mask_key[i] = self.buf[offset + i];
            offset += 4;
        }

        // Ensure we have full payload available
        const payload_len_usize: usize = @intCast(payload_len_small);
        if (self.write_pos < offset + payload_len_usize) return WsError.IncompleteFrame;

        // Validate opcode
        var opcode: Opcode = undefined;
        switch (opcode_val) {
            0 => opcode = Opcode.Continuation,
            1 => opcode = Opcode.Text,
            2 => opcode = Opcode.Binary,
            8 => opcode = Opcode.Close,
            9 => opcode = Opcode.Ping,
            10 => opcode = Opcode.Pong,
            else => return WsError.InvalidOpcode,
        }

        // Control frame rules
        if ((opcode == Opcode.Close or opcode == Opcode.Ping or opcode == Opcode.Pong) and !fin) {
            return WsError.ProtocolError; // control frames must not be fragmented
        }
        if ((opcode == Opcode.Close or opcode == Opcode.Ping or opcode == Opcode.Pong) and payload_len_usize > 125) {
            return WsError.ProtocolError; // control frames must have payload <= 125
        }

        if (payload_len_usize > self.max_message_size) return WsError.PayloadTooLarge;

        // Extract payload
        const payload_slice = self.buf[offset .. offset + payload_len_usize];

        // Unmask if needed into arena-allocated buffer
        var payload_unmasked: []u8 = undefined;
        if (payload_len_usize == 0) {
            payload_unmasked = &[_]u8{};
        } else {
            payload_unmasked = try self.allocator.alloc(u8, payload_len_usize);
            if (masked) {
                for (payload_slice, 0..) |b, i| {
                    payload_unmasked[i] = b ^ mask_key[i % 4];
                }
            } else {
                @memcpy(payload_unmasked, payload_slice);
            }
        }

        // Advance internal buffer (consume frame bytes)
        const consumed = offset + payload_len_usize;
        // shift remaining data to start of storage
        const remaining = self.write_pos - consumed;
        if (remaining > 0) {
            @memcpy(self.storage[0..remaining], self.storage[consumed .. consumed + remaining]);
        }
        self.write_pos = remaining;
        self.buf = self.storage[0..self.write_pos];

        // Interpret message types
        switch (opcode) {
            Opcode.Text => {
                if (validate_utf8) {
                    const res = std.unicode.utf8ValidateSlice(payload_unmasked);
                    if (!res) {
                        self.allocator.free(payload_unmasked);
                        return WsError.InvalidUtf8;
                    }
                }
                return Message{ .Text = payload_unmasked };
            },
            Opcode.Binary => return Message{ .Binary = payload_unmasked },
            Opcode.Ping => return Message{ .Ping = payload_unmasked },
            Opcode.Pong => return Message{ .Pong = payload_unmasked },
            Opcode.Close => {
                var code: u16 = 0;
                var reason: []u8 = &[_]u8{};
                if (payload_unmasked.len >= 2) {
                    code = std.fmt.parseInt(u16, payload_unmasked[0..2], 10) catch return WsError.ProtocolError;
                    reason = payload_unmasked[2..];
                } else {
                    if (payload_unmasked.len == 1) {
                        // protocol error: close payload length 1 is invalid
                        self.allocator.free(payload_unmasked);
                        return WsError.ProtocolError;
                    }
                    reason = payload_unmasked;
                }
                return Message{ .Close = .{ .code = code, .reason = reason } };
            },
            Opcode.Continuation => {
                // A full implementation would accumulate and handle fragments.
                // For brevity: treat a standalone continuation without prior state as protocol error.
                self.allocator.free(payload_unmasked);
                return WsError.Unsupported;
            },
            _ => {
                self.allocator.free(payload_unmasked);
                return WsError.InvalidOpcode;
            },
        }
    }
};

pub fn sendFrame(client: *Client, opcode: Opcode, payload: []const u8) !void {
    var header: [10]u8 = undefined;
    var i: usize = 0;

    header[i] = @intFromEnum(opcode); // FIN bit set
    header[i] = header[0] | 0x80;
    i += 1;

    if (payload.len <= 125) {
        header[i] = @intCast(payload.len);
        i += 1;
    } else if (payload.len <= 65535) {
        header[i] = 126;
        i += 1;
        var len_bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_bytes, @intCast(payload.len), .big);
        @memcpy(header[i .. i + 2], &len_bytes);
        i += 2;
    } else {
        header[i] = 127;
        i += 1;
        var len_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &len_bytes, @intCast(payload.len), .big);
        @memcpy(header[i .. i + 8], &len_bytes);
        i += 8;
    }

    try client.fillWriteBuffer(header[0..i]);
    try client.fillWriteBuffer(payload);
    _ = try client.writeMessage();
}

pub fn sendText(ws: *Websocket, payload: []const u8) !void {
    try sendFrame(ws.client, Opcode.Text, payload);
}
pub fn sendBinary(ws: *Websocket, payload: []const u8) !void {
    try sendFrame(ws.client, Opcode.Binary, payload);
}
pub fn sendPing(ws: *Websocket, payload: []const u8) !void {
    if (payload.len > 125) return WsError.PayloadTooLarge;
    try sendFrame(ws.client, Opcode.Ping, payload);
}
pub fn sendPong(ws: *Websocket, payload: []const u8) !void {
    if (payload.len > 125) return WsError.PayloadTooLarge;
    try sendFrame(ws.client, Opcode.Pong, payload);
}
pub fn sendClose(ws: *Websocket, code: u16, reason: []const u8) !void {
    var buf: []u8 = &[_]u8{};
    const total_len = 2 + reason.len;
    buf = try std.heap.c_allocator.alloc(u8, total_len);
    // big-endian close code
    buf[0] = @intCast((code >> 8) & 0xFF);
    buf[1] = @intCast((code >> 0) & 0xFF);
    @memcpy(buf[2..], reason);
    defer std.heap.c_allocator.free(buf);
    try sendFrame(ws.client, Opcode.Close, buf);
}
