const std = @import("std");
const utils = @import("utils.zig");
const base = @import("base.zig");
const Scheduler = @import("Scheduler.zig");
const Stack = @import("types.zig").Stack;
const StackConstruct = @import("Stack.zig");
const Fiber = @import("Fiber.zig");
const Frame = base.Frame;

/// The signature of a coroutine.
/// Considering a coroutine a generalization of a regular function,
/// it has the typical input arguments and outputs (Func) and also
/// the types of its yielded (YieldT) and injected (InjectT) values.
pub const Signature = @This();
Func: type,
YieldT: type = void,
InjectT: type = void,
ArgsT: type,
/// If the function this signature represents is compile-time known,
/// it can be held here.
func_ptr: ?type = null,

// Step 4
// Here we pass the func and determine the args type
// here we check if the Func passed is a type or a function itself
pub fn init(comptime Func: anytype, options: Options) Signature {
    const FuncT = if (@TypeOf(Func) == type) Func else @TypeOf(Func);
    return .{
        .Func = FuncT,
        .YieldT = options.YieldT,
        .InjectT = options.InjectT,
        // ArgsT is the options if set, in our case options is .{}
        // hence we set the type of ArgsT to FuncT arguments
        .ArgsT = options.ArgsT orelse ArgsTuple(FuncT),
        // Here we set the val to the Func itselft so pub "fn incr() void {}" for example
        .func_ptr = if (@TypeOf(Func) == type) null else struct {
            const val = Func;
        },
    };
}

// This takes the Signature itself and determeines the ReturnType of the Function
pub fn ReturnT(comptime self: Signature) type {
    return @typeInfo(self.Func).@"fn".return_type.?;
}

// ============================================================================
const Options = struct {
    YieldT: type = void,
    InjectT: type = void,
    ArgsT: ?type = null,
};

pub fn ArgsTuple(comptime Fn: type) type {
    const out = std.meta.ArgsTuple(Fn);
    return if (std.meta.fields(out).len == 0) @TypeOf(.{}) else out;
}
// Step 3
// From func calls init first
/// fromSig generates a comptime type signature from a function, this is used to inject arguments
pub fn fromFunc(comptime Func: anytype, comptime options: Options) type {
    return fromSig(Signature.init(Func, options));
}

// Step 5
// fromSig takes a the Signature which we determined with fromFunc using ArgsTuple
// it returns a type
pub fn fromSig(comptime Sig: Signature) type {
    if (Sig.func_ptr == null) @compileError("Fiber function must be comptime known");

    // Stored in the _fiber stack
    // InnerStorage is a struct which contains the ArgsT of the Func
    // for example now since we determined ArgsT to be *usize
    // the inner storage holds this data
    // retval is the ReturnT of Signature
    // retvale is the ReturnType of our Function
    const InnerStorage = struct {
        args: Sig.ArgsT,
        /// Values that are produced during coroutine execution
        value: union {
            yieldval: Sig.YieldT,
            injectval: Sig.InjectT,
            retval: Sig.ReturnT(),
        } = undefined,
    };

    return struct {
        const Self = @This();
        pub const Signature = Sig;

        _fiber: *Fiber,

        /// Create aFiber
        /// self and stack pointers must remain stable for the lifetime of
        /// the coroutine.
        pub fn init(
            args: Sig.ArgsT,
            stack: Stack,
        ) !Self {
            // Here is where the magic happens
            var s = StackConstruct.init(stack);
            const inner = try s.push(InnerStorage);
            // then we set the inner stack storage ptr to the args passed
            inner.* = .{
                .args = args,
            };
            // then we create a new _fiber from teh stack
            // we pass the inner as an anyopaque because we will cast it into the correct
            // type later
            return .{ ._fiber = try Scheduler.initFromStack(wrapfn, &s, inner) };
        }

        pub fn fiber(self: Self) *Fiber {
            return self._fiber;
        }

        pub fn status(self: @This()) Fiber.Fiber.Status {
            return self._fiber.f_status;
        }

        fn wrapfn() !void {
            // Here we pass the InnerStaogreType to get out the storage
            // with the correct storage type
            const storage = Scheduler.maker_state.currentStorage(InnerStorage);
            storage.value = .{ .retval = @call(
                .always_inline,
                Sig.func_ptr.?.val,
                storage.args,
            ) };
        }

        /// Intermediate resume, takes injected value, returns yielded value
        pub fn xnext(self: Self, val: Sig.InjectT) Sig.YieldT {
            const storage = self._fiber.getStorage(InnerStorage);
            storage.value = .{ .injectval = val };
            Scheduler.xresume(self._fiber);
            return storage.value.yieldval;
        }

        // What we do is the following to function work in tandem
        // when we call xresume then we are calling xyield and since xyeild
        // is a function which takes a val and sets it to the yeild value then
        // when we suspend and go back teh yield value is returned
        /// Intermediate resume, takes injected value, returns yielded value
        pub fn xnextNoop(self: Self) Sig.YieldT {
            const storage = self._fiber.getStorage(InnerStorage);
            storage.value = .{ .injectval = undefined };
            Scheduler.xresume(self._fiber);
            return storage.value.yieldval;
        }

        pub fn xnextEnd(self: Self, val: Sig.InjectT) Sig.ReturnT() {
            // Here we get the storage which is just the anyopaque ptrCasted into the correct
            // comptime value
            const storage = self._fiber.getStorage(InnerStorage);
            storage.value = .{ .injectval = val };
            Scheduler.xresume(self._fiber);
            return storage.value.retval;
        }

        /// Yields value, returns injected value
        pub fn xyield(val: Sig.YieldT) Sig.InjectT {
            const storage = Scheduler.maker_state.currentStorage(InnerStorage);
            storage.value = .{ .yieldval = val };
            Scheduler.xsuspend();
            return storage.value.injectval;
        }

        /// Yields value, returns injected value
        pub fn xyieldNoop() Sig.InjectT {
            const storage = Scheduler.maker_state.currentStorage(InnerStorage);
            storage.value = .{ .yieldval = undefined };
            Scheduler.xsuspend();
            return storage.value.injectval;
        }
    };
}
