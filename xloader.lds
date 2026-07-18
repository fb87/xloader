OUTPUT_FORMAT(elf64-littleaarch64)
OUTPUT_ARCH(aarch64)
ENTRY(_image_start)

PHDRS
{
  text PT_LOAD FLAGS(5);   /* PF_R | PF_X */
  data PT_LOAD FLAGS(6);   /* PF_R | PF_W */
  bss  PT_LOAD FLAGS(6);
}

SECTIONS
{
    . = BASE_ADDR;

    .text : { *(.text.image_header) *(.text.entry) *(.text*) } :text
    .rodata : { *(.rodata*) } :text
    .data : { *(.data*) } :data

    .bss : ALIGN(16) {
        _bss_start = .;
        *(.bss*); *(COMMON);
        . = ALIGN(16);
        _bss_end = .;
        . = ALIGN(4096);
        _dtb_buffer = .;
        . = . + 0x200000;
    } :bss
    _stack_start = .;
    . = . + 0x4000;
    _stack_end = .;

    _xloader_end = .;

    /DISCARD/ : { *(.comment*) *(.ARM.*) *(.note.*) *(.eh_frame*) }
}
