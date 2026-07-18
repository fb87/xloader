.section .text.entry, "ax"

#ifdef XL_IMAGE_HEADER
.section .text.image_header, "ax"
.globl _image_start
_image_start:
    /* ARM64 Linux boot Image header (64 bytes)
     *
     * Offset  Size  Field
     * ------  ----  -----
     *  0x00    4    b _start        — entry point (branches to _start)
     *  0x04    4    reserved
     *  0x08    8    text_offset     — 0 = relocatable
     *  0x10    8    image_size      — total memory footprint
     *  0x18    8    flags           — see below
     *  0x20    8    reserved
     *  0x28    8    reserved
     *  0x30    8    reserved
     *  0x38    4    "ARM\x64"       — AArch64 magic (0x644d5241)
     *  0x3C    4    reserved
     *
     * Flags:
     *   bit 0:   0 = LE,     1 = BE
     *   bit 1:   0 = 4K pg,  1 = 16K/64K pg
     *   bits[3:2]: 00 = 2MB align recommended
     *              01 = 2MB align required
     *              10 = 64K align required
     */
    b       _start
    .word   0                         /* reserved */
    .quad   0                         /* text_offset — relocatable */
    .quad   _xloader_end - _image_start /* image_size */
    .quad   0x08                      /* flags: LE, 4K pages, 2MB align required */
    .quad   0                         /* reserved */
    .quad   0                         /* reserved */
    .quad   0                         /* reserved */
    .word   0x644d5241                /* "ARM\x64" magic */
    .word   0                         /* reserved */
.text
.section .text.entry, "ax"
#else
.globl _image_start
_image_start = _start
#endif

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
