.global _asm_stack_swap
_asm_stack_swap:
.global asm_stack_swap
asm_stack_swap:

# now we want to allocate memory into the sp
# sub is subtract where we subtract 0xa0 160 bytes from sp
sub sp, sp, 0xa0
# d* are the 128-bit floating point registers, the lower 64 bits are preserved
stp d8,   d9, [sp, 0x00]
stp d10, d11, [sp, 0x10]
stp d12, d13, [sp, 0x20]
stp d14, d15, [sp, 0x30]
# x* are the scratch registers
stp x19, x20, [sp, 0x40]
stp x21, x22, [sp, 0x50]
stp x23, x24, [sp, 0x60]
stp x25, x26, [sp, 0x70]
stp x27, x28, [sp, 0x80]
# fp=frame pointer, lr=link register
# register 19 is lr 
stp fp,   lr, [sp, 0x90]

# Modify stack pointer of current coroutine (x0, first argument)
# mov is the call to move a value into a varaible name x2 so we move sp into x2
# x0 or x5 or x10 is a gpr so we are moving the sp into register 2
# here we move the current sp into x2 then str x2 into our variable x0 register
mov x2, sp
# str is the store, here we store x2 into x0 variable
str x2, [x0, 0]

# Load stack pointer from target coroutine (x1, second argument)
# here we load our target coruoitne and move it into the sp
ldr x9, [x1, 0]
mov sp, x9

# Restore target registers
# then we load all the data into our stack pointer
ldp d8,   d9, [sp, 0x00]
ldp d10, d11, [sp, 0x10]
ldp d12, d13, [sp, 0x20]
ldp d14, d15, [sp, 0x30]
ldp x19, x20, [sp, 0x40]
ldp x21, x22, [sp, 0x50]
ldp x23, x24, [sp, 0x60]
ldp x25, x26, [sp, 0x70]
ldp x27, x28, [sp, 0x80]
ldp fp,   lr, [sp, 0x90]

# Pop stack frame
# then we pop from the stack
# this adds 160 bytes back to the stack pointer
add sp, sp, 0xa0

# jump to lr
ret
