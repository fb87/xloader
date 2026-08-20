.section .text.boot, "ax"
.p2align 7
.global _start
.type   _start, %function
_start:
    /* Preserve the initial boot registers; QEMU/firmware may place the DTB in x0 or x1. */
    mov     x19, x0

    adrp    x1, __stack_top
    add     x1, x1, :lo12:__stack_top
    mov     sp, x1

    adrp    x1, __bss_start
    add     x1, x1, :lo12:__bss_start
    adrp    x2, __bss_end
    add     x2, x2, :lo12:__bss_end
1:
    cmp     x1, x2
    b.hs    2f
    str     xzr, [x1], #8
    b       1b
2:
    mov     x0, x19
    bl      xloader_main
3:
    wfe
    b       3b
.size _start, . - _start
