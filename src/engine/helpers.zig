const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const crypto = std.crypto;
const fmt = std.fmt;
const print = std.debug.print;

pub const Ctx_pm = struct {
    // path: [9]u8 = [9]u8{ '/', 'a', 'p', 'i', '/', 't', 'e', 's', 't' },
    // path: []const u8 = undefined,
    path: []const u8 = "",
    // method: []const u8 = undefined,
    method: []const u8 = "GET",
};

const ServerError = error{
    HeaderMalformed,
    RequestNotSupported,
    ProtoNotSupported,
    InternalServerError,
    MalformedFormContentType,
};

const CookieTypes = enum {
    // Authorization,
    Session,
};

const RequestTypes = enum {
    OPTIONS,
    GET,
    POST,
    PATCH,
    PUT,
    DELETE,
};

pub const ConnectionTypes = enum {
    Upgrade,
    Keep_Alive,
};

const Header = enum {
    Host,
    @"User-Agent",
    Cookie,
    Accept,
    Upgrade,
    @"Content-Type",
    @"Accept-Language",
    @"Accept-Encoding",
    @"Access-Control-Request-Method",
    @"Access-Control-Request-Headers",
    @"Sec-WebSocket-Key",
    @"Sec-WebSocket-Version",
};
pub const ContentType = enum {
    None,
    Text,
    Form,
    MultiForm,
    JSON,
};

pub const HTTPHeader = struct {
    request_line: []const u8 = "",
    origin: []const u8 = "",
    host: []const u8 = "",
    accept: []const u8 = "",
    upgrade: []const u8 = "",
    user_agent: []const u8 = "",
    cookie: []const u8 = "",
    cookie_str: []const u8 = "",
    content_type: ContentType = ContentType.None,
    content_length: usize = 0,
    connection: []const u8 = "",
    path: []const u8 = "",
    // cookies: std.ArrayList([]const u8),
    method: []const u8 = "",
    accept_language: []const u8 = "",
    accept_encoding: []const u8 = "",
    accept_control_request_method: []const u8 = "",
    accept_control_request_headers: []const u8 = "",
    boundary: ?[]const u8 = "",
    ws_version: []const u8 = "",
    ws_client_key: []const u8 = "",
    referer: []const u8 = "",
    body: []const u8 = "",

    pub fn init(_: *std.mem.Allocator) !HTTPHeader {
        return HTTPHeader{
            .request_line = undefined,
            .host = undefined,
            .upgrade = undefined,
            .accept = undefined,
            .user_agent = undefined,
            .cookie = undefined,
            // .cookies = std.ArrayList([]const u8).init(arena.*),
            .method = undefined,
            .content_type = ContentType.None,
            .accept_language = undefined,
            .accept_encoding = undefined,
            .accept_control_request_method = null,
            .accept_control_request_headers = undefined,
            .boundary = null,
            .ws_version = undefined,
            .ws_client_key = undefined,
        };
    }
};

pub fn findIndex(haystack: []const u8, needle: u8) ?usize {
    const vec_len = 16;
    const Vec16 = @Vector(16, u8);
    const splt_16: Vec16 = @splat(@as(u8, needle));
    if (haystack.len >= vec_len) {
        var i: usize = 0;
        while (i + vec_len <= haystack.len) : (i += vec_len) {
            const v = haystack[i..][0..vec_len].*;
            const vec: Vec16 = @bitCast(v);
            const mask = vec == splt_16;
            const bits: u16 = @bitCast(mask);
            if (bits != 0) {
                return i + @ctz(bits);
            }
        }
    }
    var i: usize = 0;
    while (i < haystack.len) : (i += 1) {
        if (haystack[i] == needle) return i;
    }
    return null;
}

pub fn findCRLFCRLF(payload: []const u8) ?usize {
    if (payload.len < 4) return null;
    if (payload.len >= 64) {
        // print("We check 64\n", .{});
        const V = @Vector(64, u8);
        const cr_pattern: V = @splat('\r');
        var i: usize = 0;

        while (i + 64 <= payload.len) : (i += 64) {
            const chunk: V = payload[i..][0..64].*;
            const cr_matches = chunk == cr_pattern;
            const cr_mask: u64 = @bitCast(cr_matches);

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

        // Check remaining bytes after last 64-byte chunk
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

    if (payload.len >= 16) {
        const V = @Vector(16, u8);
        const cr_pattern: V = @splat('\r');
        var i: usize = 0;

        while (i + 16 <= payload.len) : (i += 16) {
            const chunk: V = payload[i..][0..16].*;
            const cr_matches = chunk == cr_pattern;
            const cr_mask: u16 = @bitCast(cr_matches);

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

        // Check remaining bytes after last 16-byte chunk
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
// Pre-computed lookup table for header types
const HeaderLookup = struct {
    // First level lookup based on first char
    first_char: [256]u8,

    pub fn init() @This() {
        var table = @This(){
            .first_char = [_]u8{0} ** 256,
        };

        // Initialize with special values for known headers
        table.first_char['G'] = 1; // GET
        table.first_char['P'] = 2; // POST/PATCH
        table.first_char['D'] = 3; // DELETE
        table.first_char['U'] = 4; // UPDATE/User-Agent
        table.first_char['H'] = 5; // Host
        table.first_char['C'] = 6; // Connection/Cookie/Content-Type/Content-Length
        table.first_char['A'] = 7; // Accept-*
        table.first_char['O'] = 8; // Origin
        table.first_char['R'] = 9; // Referer
        table.first_char['S'] = 10; // Referer

        return table;
    }
}.init();

// Pre-allocated buffer for common strings
const CommonStrings = struct {
    get: []const u8 = "GET",
    post: []const u8 = "POST",
    patch: []const u8 = "PATCH",
    delete: []const u8 = "DELETE",
    update: []const u8 = "UPDATE",
    options: []const u8 = "OPTIONS",
};
const commonStrings = CommonStrings{};

/// Find the index of '\r' in the slice. For slices 32 bytes or longer, use a SIMD‐like approach.
const V64 = @Vector(64, u8);
const splt: V64 = @splat(@as(u8, '\r'));

const V32 = @Vector(32, u8);
const splt_32: V32 = @splat(@as(u8, '\r'));
pub fn findCRLF(slice: []const u8) usize {
    if (slice.len >= 64) {
        var i: usize = 0;
        while (i + 64 <= slice.len) : (i += 64) {
            const v = slice[i..][0..64].*;
            const vec: V64 = @bitCast(v);
            const mask = vec == splt;
            const bits: u64 = @bitCast(mask);
            if (bits != 0) {
                return i + @ctz(bits);
            }
        }
    }
    if (slice.len >= 32) {
        var i: usize = 0;
        while (i + 32 <= slice.len) : (i += 32) {
            const v = slice[i..][0..32].*;
            const vec: V32 = @bitCast(v);
            const mask = vec == splt_32;
            const bits: u32 = @bitCast(mask);
            if (bits != 0) {
                return i + @ctz(bits);
            }
        }
    }

    var i: usize = 0;
    while (i < slice.len) : (i += 1) {
        if (slice[i] == '\r') return i;
    }
    return slice.len;
}
// Precomputed method trie (compile-time)
const MethodTrie = struct {
    const masks = [4]u64{
        0x0000_0000_FFFF_FF00, // GET
        0x0000_0000_FFFF_FFFF, // POST
        0x0000_0000_FFFF_FF00, // PUT
        0x0000_0000_FFFF_FF00, // HEAD
    };
    const v1 =
        (@as(u64, 'G') << 0) |
        (@as(u64, 'E') << 8) |
        (@as(u64, 'T') << 16) |
        (@as(u64, ' ') << 24);
    const v2 =
        (@as(u64, 'P') << 0) |
        (@as(u64, 'O') << 8) |
        (@as(u64, 'S') << 16) |
        (@as(u64, 'T') << 24);
    const v3 =
        (@as(u64, 'P') << 0) |
        (@as(u64, 'U') << 8) |
        (@as(u64, 'T') << 16) |
        (@as(u64, ' ') << 24);
    const v4 =
        (@as(u64, 'H') << 0) |
        (@as(u64, 'E') << 8) |
        (@as(u64, 'A') << 16) |
        (@as(u64, 'D') << 24);
    const values = [4]u64{ v1, v2, v3, v4 };
};

var http_header: HTTPHeader = HTTPHeader{};
pub fn parseHeaders(payload: []const u8, ctx_pm: *Ctx_pm) *HTTPHeader {
    // Allocate space for the copy (same length as original)
    var is_first_line = true; // Track if we're on the request line
    var i: usize = 0;
    var line_start: usize = 0;

    if (is_first_line) {
        const header_type = HeaderLookup.first_char[payload[0]];
        switch (header_type) {
            1 => ctx_pm.method = commonStrings.get,
            2 => ctx_pm.method = switch (payload[1]) {
                'O' => commonStrings.post,
                else => commonStrings.patch,
            },
            3 => ctx_pm.method = commonStrings.delete,
            4 => switch (payload[1]) {
                'P' => ctx_pm.method = commonStrings.update,
                else => {},
            },
            else => {},
        }
        // Find CRLF with SIMD+word scan
        const sentinal = findCRLF(payload);

        // Direct path assignment (no copy)
        const value = payload[ctx_pm.method.len + 1 .. sentinal];
        ctx_pm.path = value[0 .. sentinal - 13];

        is_first_line = false;

        i = sentinal + 1;
        line_start = i + 1;
    }

    const last = findCRLFCRLF(payload).?;
    http_header.body = payload[last + 4 ..];
    while (i < last) : (i += 1) {
        const c = payload[i];
        if (c != ' ') continue;

        // Quick lookup using pre-computed table
        const header_type = HeaderLookup.first_char[payload[line_start]];
        if (header_type == 0) {
            i = findCRLF(payload[i..]) + i + 1;
            continue;
        }

        const sentinal = findCRLF(payload[i..]) + i;
        const value = payload[i + 1 .. sentinal];

        // Use computed goto pattern for better performance than switch
        switch (header_type) {
            4 => switch (payload[line_start + 1]) {
                's' => http_header.user_agent = value,
                else => {},
            },
            5 => {
                http_header.host = value;
            },
            6 => switch (payload[line_start + 2]) {
                'o' => http_header.cookie_str = value,
                'n' => {
                    switch (payload[line_start + 8]) {
                        // Here we check if we are looking at Content-Type or Content-Length
                        'l', 'L' => {
                            http_header.content_length = std.fmt.parseInt(usize, value, 10) catch 0;
                        },
                        't', 'T' => {
                            type_sw: switch (value[0]) {
                                'a' => {
                                    if (value[12] == 'x') continue :type_sw 'x';
                                    if (value[12] == 'j') continue :type_sw 'j';
                                },
                                't' => {
                                    http_header.content_type = ContentType.Text;
                                },
                                'x' => {
                                    http_header.content_type = ContentType.Form;
                                },
                                'j' => {
                                    http_header.content_type = ContentType.JSON;
                                },
                                'm' => {
                                    http_header.content_type = ContentType.MultiForm;
                                },
                                else => unreachable,
                            }
                        },
                        'o' => {
                            http_header.connection = value;
                        },
                        else => {},
                    }
                },
                else => {},
            },
            7 => if (line_start + 7 < payload.len) switch (payload[line_start + 7]) {
                'L' => http_header.accept_language = value,
                'E' => http_header.accept_encoding = value,
                'C' => if (line_start + 23 < payload.len) switch (payload[line_start + 23]) {
                    'M' => http_header.accept_control_request_method = value,
                    'H' => http_header.accept_control_request_headers = value,
                    else => {},
                },
                else => {},
            },
            8 => switch (payload[line_start + 1]) {
                'r' => {
                    http_header.origin = value;
                },
                'P' => {
                    http_header.method = commonStrings.options;
                },
                else => {},
            },
            9 => http_header.referer = value,
            10 => {
                if (payload[line_start + 4] == 'W') {
                    if (payload[line_start + 14] == 'K') {
                        http_header.ws_client_key = value;
                    }
                }
            },
            else => {},
        }

        i = sentinal + 1;
        line_start = i + 1;
    }


    return &http_header;
}
