.section .text.entry, "ax"

#ifdef XL_IMAGE_HEADER
.section .text.image_header, "ax"
.globl _image_start
_image_start:
    .byte 0x4d, 0x5a, 0x00, 0x91          /* "MZ" → add x13, x18, #0x16 (harmless) */
    b       _start                         /* branch over the header */
    .quad   0          /* text_offset — 0 = relocatable */
    .8byte  _xloader_end - _image_start    /* image_size  */
    .quad   0          /* flags: LE (bit0=0), 4K pages (bit1=0) */
    .byte   0x41, 0x52, 0x4d, 0x64         /* "ARM\x64" magic */
    .long   0          /* reserved */
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
