const std = @import("std");
const Client = @import("Client.zig");
const Pool = @This();
client_list: []Client,
free_list: []usize,
free_list_index: usize = 0,
allocator: std.mem.Allocator,

// Pool is a singly linked list of nodes, each node contains a pointer to a Client
// The pool is used to manage a pool of clients that can be reused
pub fn init(allocator: std.mem.Allocator, number_of_clients: usize) Pool {
    var client_list = try allocator.alloc(Client, number_of_clients);
    var free_list = try allocator.alloc(usize, number_of_clients);
    for (0..number_of_clients) |i| {
        const client = try allocator.create(Client);
        client_list[i] = client.*;
        free_list[i] = i;
    }

    return .{
        .allocator = allocator,
        .free_list = free_list,
        .free_list_index = number_of_clients,
        .client_list = client_list,
    };
}

pub fn getClient(self: *Pool) !*Client {
    if (self.free_list_index == 0) return error.NoClientsAvailable;
    self.free_list_index -= 1;
    const slot_index = self.free_list[self.free_list_index];
    return &self.client_list[slot_index];
}

pub fn freeClient(self: *Pool, client: *Client) void {
    // Calculate the index by pointer arithmetic using @sizeOf
    const slot_index = (@intFromPtr(client) - @intFromPtr(self.client_list.ptr)) / @sizeOf(Client);

    // Push back to freelist
    self.free_list[self.free_list_index] = slot_index;
    self.free_list_index += 1;
}

pub fn deinit(self: *Pool) void {
    self.allocator.free(self.client_list);
    self.allocator.free(self.free_list);
}

test "string pool" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() != .ok) @panic("Memmory leak...");
    const allocator = gpa.allocator();

    var pool = try Pool.init(allocator, 10);
    defer pool.deinit(allocator);

    const client1 = try pool.getClient();
    const client2 = try pool.getClient();
    const client3 = try pool.getClient();
    const client4 = try pool.getClient();
    const client5 = try pool.getClient();
    const client6 = try pool.getClient();
    const client7 = try pool.getClient();
    const client8 = try pool.getClient();
    const client9 = try pool.getClient();
    const client10 = try pool.getClient();

    try std.testing.expectEqual(pool.free_list_index, 10);

    pool.freeClient(client1);
    pool.freeClient(client2);
    pool.freeClient(client3);
    pool.freeClient(client4);
    pool.freeClient(client5);
    pool.freeClient(client6);
    pool.freeClient(client7);
    pool.freeClient(client8);
    pool.freeClient(client9);
    pool.freeClient(client10);

    try std.testing.expectEqual(pool.free_count_32, 10);
}
