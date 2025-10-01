const std = @import("std");
const utils = @import("utils.zig");
const base = @import("base.zig");
const Scheduler = @import("Scheduler.zig");
const Signature = @import("Signature.zig");
const Stack = @import("types.zig").Stack;
const StackConstruct = @import("Stack.zig");
const Frame = base.Frame;

pub const Status = enum {
    Start,
    Suspended,
    Active,
    Done,
    Error,
};

pub const Fiber = @This();
f_status: Status = .Start,
func: *const fn () anyerror!void,
f_frame: Frame,
storage: ?*anyopaque = null,
err: ?anyerror = null,
id: usize,
/// The coroutine that will be yielded to upon suspend
caller: *Fiber = undefined,

pub fn frame(self: *Fiber) *Fiber {
    return self;
}

pub fn status(self: *Fiber) Status {
    return self.status;
}

// Here we take the Frame and grab the parentPtr of the Frame which is theFiber
pub fn run(current: *Frame, target: *Frame) callconv(.c) noreturn {
    const current_coro: *Fiber = @fieldParentPtr("f_frame", current);
    const target_coro: *Fiber = @fieldParentPtr("f_frame", target);

    @call(.auto, target_coro.func, .{}) catch |err| {
        target_coro.f_status = .Error;
        target_coro.err = err;
        Scheduler.maker_state.switchOut(current_coro);
    };
    target_coro.f_status = Status.Done;
    _ = Scheduler.maker_state.fiber_count.fetchSub(1, .seq_cst);
    // Here we take the target and switch back to the root when finished
    Scheduler.maker_state.switchOut(current_coro);

    // Never returns
    const err_msg = "Cannot resume an already completed coroutine";
    std.debug.panic(
        err_msg,
        .{},
    );
}

// Step 2
// Here we call fromFunc to deteremine the args type
// it is const since we are do comptime ops
pub fn init(func: anytype, args: anytype, stack: Stack) !*Fiber {
    const sig = Signature.fromFunc(func, .{});
    var fiber_sig = try sig.init(args, stack);
    const fiber = fiber_sig.fiber();
    return fiber;
}

pub fn getStorage(self: *Fiber, comptime T: type) *T {
    return @ptrCast(@alignCast(self.storage));
}
