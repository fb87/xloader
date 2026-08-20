OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

SECTIONS
{
    . = 0;
    __image_start = .;

    .multiboot ALIGN(4) : { KEEP(*(.multiboot)) }
    .text ALIGN(16) : { KEEP(*(.text.boot)) *(.text .text.*) }
    .rodata ALIGN(16) : { *(.rodata .rodata.*) }
    .data ALIGN(16) : {
        *(.data .data.*)
        . = ALIGN(16);
        KEEP(*(.xbundle))
    }
    .bss ALIGN(4096) (NOLOAD) : {
        __bss_start = .;
        *(.bss .bss.* COMMON)
        __bss_end = .;
    }
    __image_end = .;
    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) *(.interp) }
}
