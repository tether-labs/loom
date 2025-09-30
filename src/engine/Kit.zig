const std = @import("std");
pub const Kit = @This();
pub const String = struct {
    start: usize,
    len: usize,
    capacity: usize,
    contents: [65535]u8 = undefined,

    pub fn new() String {
        return String{
            .start = 0,
            .len = 0,
            .capacity = 65535,
        };
    }

    pub fn init(initial: []const u8) String {
        var new_string = String.new();
        new_string.append_str(initial);
        return new_string;
    }

    pub fn append_str(self: *String, input: []const u8) void {
        const required_len = self.len + input.len;
        const required_capacity = required_len + (10 - required_len % 10);

        // Case 1: contents exists and is big enough
        if (required_capacity <= self.capacity) {
            @memcpy(self.contents[self.len .. self.len + input.len], input);
            self.len = required_len;
        }
    }
};

pub const HttpHeader = struct {
    name: []const u8,
    value: []const u8,
};

const Headers = struct {
    content_type: []const u8 = "text/html",
    authorization: ?[]const u8 = null,
    accept: ?[]const u8 = null,
    user_agent: ?[]const u8 = null,
};

const BodyType = enum {
    string,
    json,
};

const Methods = enum {
    GET,
    POST,
    PATCH,
    DELETE,
    OPTIONS,
};

pub const HttpReq = struct {
    method: Methods,
    headers: ?Headers = null,
    body: ?[]const u8 = null,
    body_type: BodyType = .string,
    mode: ?[]const u8 = null,
    redirect: ?[]const u8 = null,
    referrer_policy: ?[]const u8 = null,
    integrity: ?[]const u8 = null,
    use_credentials: bool = false,
    credentials: ?[]const u8 = null,
    extra_headers: []const HttpHeader = &.{},
};

fn getUnderlyingType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => std.meta.Child(T),
        else => T,
    };
}

fn getUnderlyingValue(comptime T: type, comptime OT: type, v: OT) T {
    return switch (@typeInfo(OT)) {
        .optional => v.?,
        else => v,
    };
}

var http_buf: [4096]u8 = undefined;
pub fn stringifyHttpReq(url: []const u8, http_req: HttpReq) []const u8 {
    var request_string = String.new();

    // Parse URL to extract path and host
    const parsed_url = parseUrl(url);

    // 1. Add HTTP method and path
    switch (http_req.method) {
        .GET => request_string.append_str("GET "),
        .POST => request_string.append_str("POST "),
        .PATCH => request_string.append_str("PATCH "),
        .DELETE => request_string.append_str("DELETE "),
        .OPTIONS => request_string.append_str("OPTIONS "),
    }

    request_string.append_str(parsed_url.path);
    request_string.append_str(" HTTP/1.1\r\n");

    // 2. Add Host header (required for HTTP/1.1)
    request_string.append_str("Host: ");
    request_string.append_str(parsed_url.host);
    request_string.append_str("\r\n");

    // 3. Add standard headers from Headers struct
    if (http_req.headers) |headers| {
        // Content-Type (only for POST/PATCH with body)
        if ((http_req.method == .POST or http_req.method == .PATCH) and http_req.body != null) {
            request_string.append_str("Content-Type: ");
            request_string.append_str(headers.content_type);
            request_string.append_str("\r\n");
        }

        // Authorization
        if (headers.authorization) |auth| {
            request_string.append_str("Authorization: ");
            request_string.append_str(auth);
            request_string.append_str("\r\n");
        }

        // Accept
        if (headers.accept) |accept| {
            request_string.append_str("Accept: ");
            request_string.append_str(accept);
            request_string.append_str("\r\n");
        }

        // User-Agent
        if (headers.user_agent) |ua| {
            request_string.append_str("User-Agent: ");
            request_string.append_str(ua);
            request_string.append_str("\r\n");
        }
    }

    // 4. Add extra headers
    for (http_req.extra_headers) |header| {
        request_string.append_str(header.name);
        request_string.append_str(": ");
        request_string.append_str(header.value);
        request_string.append_str("\r\n");
    }

    // 5. Add Content-Length if there's a body
    if (http_req.body) |body| {
        request_string.append_str("Content-Length: ");

        // Convert body length to string
        var length_buf: [20]u8 = undefined;
        const length_str = std.fmt.bufPrint(&length_buf, "{}", .{body.len}) catch "0";
        request_string.append_str(length_str);
        request_string.append_str("\r\n");
    }

    // 6. Add Connection header (default to close for simplicity)
    request_string.append_str("Connection: close\r\n");

    // 7. End headers with empty line
    request_string.append_str("\r\n");

    // 8. Add body if present
    if (http_req.body) |body| {
        request_string.append_str(body);
    }

    // Return the slice of the actual content
    return request_string.contents[0..request_string.len];
}

// Helper struct to hold parsed URL components
const ParsedUrl = struct {
    host: []const u8,
    path: []const u8,
    port: u16,
};

// Simple URL parser for HTTP URLs
fn parseUrl(url: []const u8) ParsedUrl {
    var remaining = url;

    // Skip "http://" if present
    if (std.mem.startsWith(u8, remaining, "http://")) {
        remaining = remaining[7..];
    }

    // Find first '/' to separate host from path
    if (std.mem.indexOf(u8, remaining, "/")) |slash_pos| {
        return ParsedUrl{
            .host = remaining[0..slash_pos],
            .path = remaining[slash_pos..],
            .port = 80,
        };
    } else {
        // No path specified, default to "/"
        return ParsedUrl{
            .host = remaining,
            .path = "/",
            .port = 80,
        };
    }
}
// pub fn fetch(url: []const u8, cb: *const fn () void, http_req: HttpReq) void {
//     var writer = String.new();
//     writer.append_str("{\n\"method\": ");
//     writer.append_str("\"");
//     writer.append_str(@tagName(http_req.method));
//     writer.append_str("\"");
//     if (http_req.headers) |headers| {
//         writer.append_str(",\n\"headers\": {\n");
//         constructHeaders(headers, http_req.extra_headers, &writer);
//         writer.append_str("\n}");
//     } else if (http_req.extra_headers.len > 0) {
//         writer.append_str(",\n\"headers\": {\n");
//         var count: usize = 1;
//         for (http_req.extra_headers) |header| {
//             writer.append_str("\"");
//             writer.append_str(header.name);
//             writer.append_str("\"");
//             writer.append_str(": ");
//             writer.append_str("\"");
//             writer.append_str(header.value);
//             writer.append_str("\"");
//             if (count < http_req.extra_headers.len) {
//                 writer.append_str(",\n");
//             }
//             count += 1;
//         }
//         writer.append_str("\n}");
//     }
//
//     if (http_req.credentials) |credentials| {
//         writer.append_str(",\n\"credentials\": ");
//         writer.append_str("\"");
//         writer.append_str(credentials);
//         writer.append_str("\"");
//     }
//
//     if (http_req.body) |body| {
//         writer.append_str(",\n\"body\": ");
//         switch (http_req.body_type) {
//             .string => {
//                 writer.append_str("\"");
//                 writer.append_str(body);
//                 writer.append_str("\"");
//             },
//             .json => {
//                 writer.append_str(body);
//             },
//         }
//     }
//     writer.append_str("\n}");
//
//     const final = writer.contents[0..writer.len];
//     const json = std.json.fmt(final, .{ .whitespace = .indent_1 }).value;
//
//     const Closure = struct {
//         fetch_node: FetchNode = .{ .data = .{ .runFn = runFn, .deinitFn = deinitFn } },
//         fn runFn(_: *FetchAction, resp: Response) void {
//             @call(.auto, cb, .{resp});
//         }
//         fn deinitFn(node: *FetchNode) void {
//             const closure: *@This() = @alignCast(@fieldParentPtr("fetch_node", node));
//             Fabric.allocator_global.destroy(closure);
//         }
//     };
//
//     const closure = Fabric.allocator_global.create(Closure) catch |err| {
//         Fabric.println("Error could not create closure {any}\n ", .{err});
//         unreachable;
//     };
//     closure.* = .{};
//
//     const id = Fabric.fetch_registry.count() + 1;
//     Fabric.fetch_registry.put(id, &closure.fetch_node) catch |err| {
//         Fabric.println("Button Function Registry {any}\n", .{err});
//         return;
//     };
//     js_fetch(url.ptr, url.len, id, json.ptr, json.len);
// }
//
// var last_time: i64 = 0;
// pub fn throttle() bool {
//     const current_time = std.time.milliTimestamp();
//     if (current_time - last_time < 8) {
//         return true;
//     }
//     last_time = current_time;
//     return false;
// }
//
// extern fn js_fetch(
//     url_ptr: [*]const u8,
//     url_len: usize,
//     callback_id: usize,
//     http_req_offset_ptr: [*]u8,
//     size: usize,
// ) void;
//
// extern fn js_fetch_params(
//     url_ptr: [*]const u8,
//     url_len: usize,
//     callback_id: usize,
//     http_req_offset_ptr: [*]u8,
//     size: usize,
// ) void;
//
// extern fn setWindowLocationWASM(
//     url_ptr: [*]const u8,
//     url_len: usize,
// ) void;
//
// pub fn setWindowLocation(url: []const u8) void {
//     if (isWasi) {
//         setWindowLocationWASM(url.ptr, url.len);
//     } else {
//         Fabric.printlnSrc("Attempted to reroute, but not wasi", .{url}, @src());
//     }
// }
//
// extern fn navigateWASM(
//     path_ptr: [*]const u8,
//     path_len: usize,
// ) void;
//
// pub fn navigate(path: []const u8) void {
//     if (isWasi) {
//         navigateWASM(path.ptr, path.len);
//     } else {
//         Fabric.printlnSrc("Attempted to reroute, but not wasi", .{path}, @src());
//     }
// }
//
// extern fn routePushWASM(
//     path_ptr: [*]const u8,
//     path_len: usize,
// ) void;
//
// pub fn routePush(path: []const u8) void {
//     if (isWasi) {
//         routePushWASM(path.ptr, path.len);
//     } else {
//         Fabric.printlnSrc("Attempted to reroute, but not wasi", .{path}, @src());
//     }
// }
//
// extern fn getWindowInformationWasm() [*:0]u8;
//
// pub fn getWindowPath() []const u8 {
//     return std.mem.span(getWindowInformationWasm());
// }
//
// extern fn getWindowParamsWASM() [*:0]u8;
//
// pub fn getWindowParams() ?[]const u8 {
//     if (isWasi) {
//         const params = getWindowParamsWASM();
//         const params_str = std.mem.span(params);
//         if (params_str.len == 0) {
//             return null;
//         } else {
//             return params_str;
//         }
//     } else {
//         Fabric.printlnSrc("Attempted to get params, but not wasi", .{}, @src());
//         return null;
//     }
// }
//
// pub fn findIndex(haystack: []const u8, needle: u8) ?usize {
//     const vec_len = 16;
//     const Vec16 = @Vector(16, u8);
//     const splt_16: Vec16 = @splat(@as(u8, needle));
//     if (haystack.len >= vec_len) {
//         var i: usize = 0;
//         while (i + vec_len <= haystack.len) : (i += vec_len) {
//             const v = haystack[i..][0..vec_len].*;
//             const vec: Vec16 = @bitCast(v);
//             const mask = vec == splt_16;
//             const bits: u16 = @bitCast(mask);
//             if (bits != 0) {
//                 return i + @ctz(bits);
//             }
//         }
//     }
//     var i: usize = 0;
//     while (i < haystack.len) : (i += 1) {
//         if (haystack[i] == needle) return i;
//     }
//     return null;
// }
//
// fn decoder(encoded: []const u8, decoded: *std.ArrayList(u8)) !void {
//     var i: usize = 0;
//     while (i < encoded.len) : (i += 1) {
//         if (encoded[i] == '%') {
//             // Ensure there's enough room for two hex characters
//             if (i + 2 >= encoded.len) {
//                 return error.InvalidInput;
//             }
//
//             const hex = encoded[i + 1 .. i + 3];
//             const decodedByte = try std.fmt.parseInt(u8, hex, 16);
//             try decoded.append(decodedByte);
//             i += 2; // Skip over the two hex characters
//         } else if (encoded[i] == '+') {
//             // Replace '+' with a space
//             try decoded.append(' ');
//         } else {
//             try decoded.append(encoded[i]);
//         }
//     }
// }
//
// pub fn parseParams(url: []const u8, allocator: *std.mem.Allocator) !?std.StringHashMap([]const u8) {
//     const params_start = findIndex(url, '?') orelse return null;
//     // Details
//     var params = std.StringHashMap([]const u8).init(allocator.*);
//
//     // Loop
//     var pos = params_start + 1;
//     while (pos < url.len) : (pos += 1) {
//         const param_pair_end = findIndex(url[pos..], '&') orelse {
//             // We only have one pair hence we add and return
//             const seperator = findIndex(url[pos..], '=') orelse return error.SeperatorNotFound;
//             const key = url[pos .. seperator + pos];
//             var decoded = std.ArrayList(u8).init(allocator.*);
//             try decoder(url[seperator + pos + 1 .. url.len], &decoded);
//             const value = try decoded.toOwnedSlice();
//             try params.put(key, value);
//             return params;
//         };
//         // now we find the sperator in this pair and add it to the hashmap and continue on to the next
//         // id=123
//         const pair = url[pos .. param_pair_end + pos];
//         const seperator = findIndex(pair, '=') orelse return error.SeperatorNotFound;
//         const key = pair[0..seperator];
//         var decoded = std.ArrayList(u8).init(allocator.*);
//         try decoder(pair[seperator + 1 ..], &decoded);
//         const value = try decoded.toOwnedSlice();
//         try params.put(key, value);
//         pos += param_pair_end;
//     }
//     return params;
// }
//
// pub const Response = struct {
//     code: u32,
//     type: []const u8,
//     text: []const u8,
//     body: []const u8,
// };
//
// export fn resumeCallback(id: u32, resp_ptr: [*:0]u8) void {
//     const resp = std.mem.span(resp_ptr);
//     const parsed_value = std.json.parseFromSlice(Response, Fabric.allocator_global, resp, .{}) catch return;
//     const json_resp: Response = parsed_value.value;
//     const node = Fabric.fetch_registry.get(id) orelse return;
//     @call(.auto, node.data.runFn, .{ &node.data, json_resp });
// }
//
// pub const HttpReqOffset = struct {
//     method_ptr: [*]const u8 = undefined,
//     method_len: usize = 0,
//     content_type_ptr: ?[*]const u8 = null,
//     content_type_len: ?usize = null,
//     authorization_ptr: ?[*]const u8 = null,
//     authorization_len: ?usize = null,
//     accept_ptr: ?[*]const u8 = null,
//     accept_len: ?usize = null,
//     user_agent_ptr: ?[*]const u8 = null,
//     user_agent_len: ?usize = null,
//     body_ptr: ?[*]const u8 = null,
//     body_len: ?usize = null,
//     extra_headers_ptr: ?[*]const HttpHeader = null,
//     extra_headers_len: ?usize = null,
//     mode_ptr: ?[*]const u8 = null,
//     mode_len: ?usize = null,
//     redirect_ptr: ?[*]const u8 = null,
//     redirect_len: ?usize = null,
//     referrer_policy_ptr: ?[*]const u8 = null,
//     referrer_policy_len: ?usize = null,
//     integrity_ptr: ?[*]const u8 = null,
//     integrity_len: ?usize = null,
//     use_credentials: bool = false,
// };
//
// pub const HttpHeader = struct {
//     name: []const u8,
//     value: []const u8,
// };
//
// const Headers = struct {
//     content_type: []const u8 = "text/html",
//     authorization: ?[]const u8 = null,
//     accept: ?[]const u8 = null,
//     user_agent: ?[]const u8 = null,
// };
//
// const BodyType = enum {
//     string,
//     json,
// };
//
// const Methods = enum {
//     GET,
//     POST,
//     PATCH,
//     DELETE,
//     OPTIONS,
// };
//
// pub const HttpReq = struct {
//     method: Methods,
//     headers: ?Headers = null,
//     body: ?[]const u8 = null,
//     body_type: BodyType = .string,
//     mode: ?[]const u8 = null,
//     redirect: ?[]const u8 = null,
//     referrer_policy: ?[]const u8 = null,
//     integrity: ?[]const u8 = null,
//     use_credentials: bool = false,
//     credentials: ?[]const u8 = null,
//     extra_headers: []const HttpHeader = &.{},
// };
//
// var http_req_view: HttpReqOffset = HttpReqOffset{};
// fn generateHttpLayout(http_req: HttpReq) *u8 {
//     http_req_view.method_ptr = @tagName(http_req.method).ptr;
//     http_req_view.method_len = @tagName(http_req.method).len;
//
//     if (http_req.headers) |h| {
//         if (h.content_type) |ct| {
//             http_req_view.content_type_ptr = ct.ptr;
//             http_req_view.content_type_len = ct.len;
//         }
//         if (h.authorization) |au| {
//             http_req_view.authorization_ptr = au.ptr;
//             http_req_view.authorization_len = au.len;
//         }
//         if (h.accept) |ac| {
//             http_req_view.accept_ptr = ac.ptr;
//             http_req_view.accept_len = ac.len;
//         }
//         if (h.user_agent) |us| {
//             http_req_view.user_agent_ptr = us.ptr;
//             http_req_view.user_agent_len = us.len;
//         }
//
//         if (http_req.extra_headers.len > 0) {
//             http_req_view.extra_headers_ptr = http_req.extra_headers.ptr;
//             http_req_view.extra_headers_len = http_req.extra_headers.len;
//         }
//     }
//     if (http_req.body) |b| {
//         http_req_view.body_ptr = b.ptr;
//         http_req_view.body_len = b.len;
//     }
//     if (http_req.mode) |m| {
//         http_req_view.mode_ptr = m.ptr;
//         http_req_view.mode_len = m.len;
//     }
//     if (http_req.redirect) |r| {
//         http_req_view.redirect_ptr = r.ptr;
//         http_req_view.redirect_len = r.len;
//     }
//     if (http_req.referrer_policy) |rp| {
//         http_req_view.referrer_policy_ptr = rp.ptr;
//         http_req_view.referrer_policy_len = rp.len;
//     }
//     if (http_req.integrity) |i| {
//         http_req_view.integrity_ptr = i.ptr;
//         http_req_view.integrity_len = i.len;
//     }
//     http_req_view.use_credentials = http_req.use_credentials;
//
//     const ptr: *u8 = @ptrCast(&http_req_view);
//     return ptr;
// }
//
// var http_buf: [4096]u8 = undefined;
// fn constructHeaders(headers: Headers, extra_headers: []const HttpHeader, writer: *String) void {
//     writer.append_str("\"Content-Type\": ");
//     writer.append_str("\"");
//     writer.append_str(headers.content_type);
//     writer.append_str("\"");
//     if (headers.user_agent) |user_agent| {
//         writer.append_str(",\n");
//         writer.append_str("\"User-Agent\": ");
//         writer.append_str("\"");
//         writer.append_str(user_agent);
//         writer.append_str("\"");
//     }
//     if (headers.authorization) |authorization| {
//         writer.append_str(",\n");
//         writer.append_str("\"Authorization\": ");
//         writer.append_str("\"");
//         writer.append_str(authorization);
//         writer.append_str("\"");
//     }
//     if (headers.accept) |accept| {
//         writer.append_str(",\n");
//         writer.append_str("\"Accept\": ");
//         writer.append_str("\"");
//         writer.append_str(accept);
//         writer.append_str("\"");
//     }
//
//     for (extra_headers) |header| {
//         writer.append_str(",\n");
//         writer.append_str("\"");
//         writer.append_str(header.name);
//         writer.append_str("\"");
//         writer.append_str(": ");
//         writer.append_str("\"");
//         writer.append_str(header.value);
//         writer.append_str("\"");
//     }
// }
//
// pub fn fetchWithParams(url: []const u8, self: anytype, cb: anytype, http_req: HttpReq) void {
//     var writer = String.new();
//     writer.append_str("{\n\"method\": ");
//     writer.append_str("\"");
//     writer.append_str(@tagName(http_req.method));
//     writer.append_str("\"");
//     if (http_req.headers) |headers| {
//         writer.append_str(",\n\"headers\": {\n");
//         constructHeaders(headers, http_req.extra_headers, &writer);
//         writer.append_str("\n}");
//     } else if (http_req.extra_headers.len > 0) {
//         writer.append_str(",\n\"headers\": {\n");
//         var count: usize = 1;
//         for (http_req.extra_headers) |header| {
//             writer.append_str("\"");
//             writer.append_str(header.name);
//             writer.append_str("\"");
//             writer.append_str(": ");
//             writer.append_str("\"");
//             writer.append_str(header.value);
//             writer.append_str("\"");
//             if (count < http_req.extra_headers.len) {
//                 writer.append_str(",\n");
//             }
//             count += 1;
//         }
//         writer.append_str("\n}");
//     }
//
//     if (http_req.credentials) |credentials| {
//         writer.append_str(",\n\"credentials\": ");
//         writer.append_str("\"");
//         writer.append_str(credentials);
//         writer.append_str("\"");
//     }
//
//     if (http_req.body) |body| {
//         writer.append_str(",\n\"body\": ");
//         switch (http_req.body_type) {
//             .string => {
//                 writer.append_str("\"");
//                 writer.append_str(body);
//                 writer.append_str("\"");
//             },
//             .json => {
//                 writer.append_str(body);
//             },
//         }
//     }
//     writer.append_str("\n}");
//
//     const final = writer.contents[0..writer.len];
//     const json = std.json.fmt(final, .{ .whitespace = .indent_1 }).value;
//     // const http_req_offset_ptr = generateHttpLayout(http_req);
//
//     const Args = @TypeOf(self);
//     const Closure = struct {
//         self: Args,
//         fetch_node: FetchNode = .{ .data = .{ .runFn = runFn, .deinitFn = deinitFn } },
//         //
//         fn runFn(action: *FetchAction, resp: Response) void {
//             const fetch_node: *FetchNode = @fieldParentPtr("data", action);
//             const closure: *@This() = @alignCast(@fieldParentPtr("fetch_node", fetch_node));
//             @call(.auto, cb, .{ closure.self, resp });
//         }
//         //
//         fn deinitFn(node: *FetchNode) void {
//             const closure: *@This() = @alignCast(@fieldParentPtr("fetch_node", node));
//             Fabric.allocator_global.destroy(closure);
//         }
//     };
//
//     const closure = Fabric.allocator_global.create(Closure) catch |err| {
//         Fabric.println("Error could not create closure {any}\n ", .{err});
//         unreachable;
//     };
//     closure.* = .{
//         .self = self,
//     };
//
//     const id = Fabric.fetch_registry.count() + 1;
//     Fabric.fetch_registry.put(id, &closure.fetch_node) catch |err| {
//         Fabric.println("Button Function Registry {any}\n", .{err});
//         return;
//     };
//     js_fetch_params(url.ptr, url.len, id, json.ptr, json.len);
// }
//
// const http = std.http;
//
// const Param = struct {
//     key: []const u8,
//     value: []const u8,
// };
//
// pub const QueryBuilder = struct {
//     allocator: std.mem.Allocator,
//     params: std.ArrayList(Param),
//     str: []const u8,
//
//     /// This function takes a pointer to this QueryBuilder instance.
//     /// Deinitializes the query builder instance
//     /// # Parameters:
//     /// - `target`: *QueryBuilder.
//     /// - `allocator`: std.mem.Allocator.
//     ///
//     /// # Returns:
//     /// void.
//     pub fn init(query_builder: *QueryBuilder, allocator: std.mem.Allocator) !void {
//         query_builder.* = .{
//             .allocator = allocator,
//             .params = std.ArrayList(Param).init(allocator),
//             .str = "",
//         };
//     }
//
//     /// This function takes a pointer to this QueryBuilder instance.
//     /// Deinitializes the query builder instance, loops over the keys and values to free
//     /// # Parameters:
//     /// - `target`: *QueryBuilder.
//     ///
//     /// # Returns:
//     /// void.
//     pub fn deinit(query_builder: *QueryBuilder) void {
//         for (query_builder.params.items) |param| {
//             query_builder.allocator.free(param.key);
//             query_builder.allocator.free(param.value);
//         }
//         query_builder.params.deinit();
//         if (query_builder.str.len > 0) {
//             query_builder.allocator.free(query_builder.str);
//         }
//     }
//
//     /// This function adds a value and key to the query builder.
//     /// # Example
//     /// try query.add("client_id", "98f3$j%gw54u4562$");
//     ///
//     /// # Parameters:
//     /// - `key`: []const u8.
//     /// - `value`: []const u8.
//     ///
//     /// # Returns:
//     /// void and adds to query builder list.
//     pub fn add(query_builder: *QueryBuilder, key: []const u8, value: []const u8) !void {
//         const key_dup = try query_builder.allocator.dupe(u8, key);
//         const value_dup = try query_builder.allocator.dupe(u8, value);
//         try query_builder.params.append(.{ .key = key_dup, .value = value_dup });
//     }
//
//     /// This function removes a key.
//     /// # Example
//     /// try query.remove("client_id");
//     ///
//     /// # Parameters:
//     /// - `key`: []const u8.
//     ///
//     /// # Returns:
//     /// void
//     pub fn remove(query_builder: *QueryBuilder, key: []const u8) !void {
//         // utils.assert_cm(query_builder.query_param_list.capacity > 0, "QueryBuilder not initilized");
//         for (query_builder.params.items, 0..) |query_param, i| {
//             if (std.mem.eql(u8, query_param.key, key)) {
//                 _ = query_builder.query_param_list.orderedRemove(i);
//                 break;
//             }
//         }
//     }
//
//     /// This function encodes the url pass.
//     /// # Example
//     /// try query.urlEncoder("https://accounts.google.com/o/oauth2/v2/auth");
//     ///
//     /// # Parameters:
//     /// - `url`: []const u8.
//     ///
//     /// # Returns:
//     /// []const u8
//     pub fn urlEncoder(query_builder: *QueryBuilder, url: []const u8) ![]const u8 {
//         var encoded = std.ArrayList(u8).init(query_builder.allocator);
//         defer encoded.deinit();
//
//         for (url) |c| {
//             switch (c) {
//                 'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.', '~' => try encoded.append(c),
//                 ' ' => try encoded.appendSlice("%20"),
//                 else => {
//                     try encoded.writer().print("%{X:0>2}", .{c});
//                 },
//             }
//         }
//
//         return encoded.toOwnedSlice();
//     }
//
//     /// This function encodes the query and set query_builder.str.
//     /// # Example
//     /// try query.queryStrEncode();
//     ///
//     /// # Returns:
//     /// void
//     pub fn queryStrEncode(query_builder: *QueryBuilder) !void {
//         if (query_builder.params.items.len == 0) {
//             query_builder.str = "";
//             return;
//         }
//
//         var list = std.ArrayList(u8).init(query_builder.allocator);
//         errdefer list.deinit();
//
//         for (query_builder.params.items, 0..) |param, i| {
//             if (i > 0) {
//                 try list.append('&');
//             }
//
//             // URL encode key
//             const encoded_key = try query_builder.urlEncoder(param.key);
//             defer query_builder.allocator.free(encoded_key);
//             try list.appendSlice(encoded_key);
//
//             try list.append('=');
//
//             // URL encode value
//             const encoded_value = try query_builder.urlEncoder(param.value);
//             defer query_builder.allocator.free(encoded_value);
//             try list.appendSlice(encoded_value);
//         }
//
//         query_builder.str = try list.toOwnedSlice();
//     }
//
//     /// This function generates the queried url plus the precursor url.
//     /// # Example
//     /// try query.generateUrl("https://accounts.google.com/o/oauth2/v2/auth", query.str);
//     ///
//     /// # Parameters:
//     /// - `base_url`: []const u8.
//     /// - `query`: []const u8.
//     ///
//     /// # Returns:
//     /// []const u8
//     pub fn generateUrl(query_builder: *QueryBuilder, base_url: []const u8, query: []const u8) ![]const u8 {
//         var result = std.ArrayList(u8).init(query_builder.allocator);
//         errdefer result.deinit();
//
//         try result.appendSlice(base_url);
//         if (query.len > 0) {
//             try result.append('?');
//             try result.appendSlice(query);
//         }
//
//         return result.toOwnedSlice();
//     }
//
//     // Helper function to get parameters in order
//     pub fn getParams(query_builder: *QueryBuilder) []const Param {
//         return query_builder.params.items;
//     }
// };
