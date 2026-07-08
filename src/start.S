.section .text.entry, "ax"
.globl _start
.type _start, %function

_start:
    mov x19, x0
    mov x20, x1

    adrp x0, _stack_end
    add x0, x0, :lo12:_stack_end
    mov sp, x0

    adrp x0, _bss_start
    add x0, x0, :lo12:_bss_start
    adrp x1, _bss_end
    add x1, x1, :lo12:_bss_end
    sub x1, x1, x0
    cbz x1, 2f

1:  str xzr, [x0], #8
    sub x1, x1, #8
    cbnz x1, 1b

2:  mov x0, x19
    bl main

loop:
    wfi
    b loop
