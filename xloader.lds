OUTPUT_FORMAT(elf64-littleaarch64)
OUTPUT_ARCH(aarch64)
ENTRY(_start)

BASE_ADDR = 0x40000000;

SECTIONS
{
    . = BASE_ADDR;

    .text : { *(.text.entry) *(.text*) }
    .rodata : { *(.rodata*) }
    .data : { *(.data*) }

    .bss : ALIGN(16) {
        _bss_start = .;
        *(.bss*); *(COMMON);
        . = ALIGN(16);
        _bss_end = .;
        . = ALIGN(4096);
        _dtb_buffer = .;
        . = . + 0x200000;
    }
    _stack_start = .;
    . = . + 0x4000;
    _stack_end = .;

    _xloader_end = .;

    /DISCARD/ : { *(.comment*) *(.ARM.*) *(.note.*) *(.eh_frame*) }
}
