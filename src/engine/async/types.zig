pub const stack_alignment = @import("base.zig").stack_alignment;
pub const Stack = []align(stack_alignment.toByteUnits()) u8;
