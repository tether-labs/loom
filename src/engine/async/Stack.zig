const std = @import("std");
const stack_alignment = @import("types.zig").stack_alignment;
const Stack = @import("types.zig").Stack;
full: Stack,
sp: [*]u8,

pub fn init(stack: Stack) @This() {
    return .{
        .full = stack,
        .sp = stack.ptr + stack.len,
    };
}

pub fn remaining(self: @This()) Stack {
    return self.full[0 .. @intFromPtr(self.sp) - @intFromPtr(self.full.ptr)];
}

// Okay so...
// here we take the storage which is the args to the function
// we pass the innerStroage type
// we calculate the size of the innerstorage since we are pushing it onto the stack
// here we the stack pointer sp and subrtact the size of the storage
// essentially what we do is round down the address to get the index of the stack pointer currently
// this give us the index
pub fn push(self: *@This(), comptime T: type) !*T {
    // What we do here is make sure the inner storage is not greater than the entire current stack
    // we align backwards from the stackpointer to check how large it is
    const ptr_i = std.mem.alignBackward(
        usize,
        @intFromPtr(self.sp - @sizeOf(T)),
        stack_alignment.toByteUnits(),
    );
    // We check the ptr_index is greater than the stack.full
    // if it is less than then the stack is too small
    if (ptr_i <= @intFromPtr(self.full.ptr)) {
        return error.StackTooSmall;
    }
    // What we do here is create space on the stack to insert our storage data
    // since the ptr_i is not larger than the full stack currently then we
    const ptr: *T = @ptrFromInt(ptr_i);
    // We move the stack pointer to the new ptr
    self.sp = @ptrFromInt(ptr_i);
    return ptr;
}
