/*
 * x86_64 xloader entry.
 *
 * Multiboot1 enters an x86 Xen-style image in 32-bit protected mode.  This
 * shim preserves the Multiboot state, establishes a minimal identity-mapped
 * long-mode environment, and calls the freestanding Zig core in 64-bit mode.
 */

.set MB_MAGIC,    0x1BADB002
.set MB_FLAGS,    0x00000003
.set MB_CHECKSUM, -(MB_MAGIC + MB_FLAGS)

.set CR4_PAE,     (1 << 5)
.set EFER_MSR,    0xC0000080
.set EFER_LME,    (1 << 8)
.set CR0_PG,      (1 << 31)
.set PAGE_P,      (1 << 0)
.set PAGE_RW,     (1 << 1)
.set PAGE_PS,     (1 << 7)

.section .multiboot, "a"
.align 4
.long MB_MAGIC
.long MB_FLAGS
.long MB_CHECKSUM

.section .text.boot, "ax"
.code32
.global _start
.type _start, @function
_start:
    cli
    cld

    /*
     * Discover the runtime image base without assuming a link/load address.
     * EBP remains the component base until the long-mode transition.
     */
    movl %eax, %edx                  /* preserve Multiboot magic temporarily */
    call 1f
1:
    popl %ebp

    /* Clear BSS using component-relative offsets. */
    xorl %eax, %eax
    leal (__bss_start - 1b)(%ebp), %edi
    leal (__bss_end - 1b)(%ebp), %ecx
    subl %edi, %ecx
    shrl $2, %ecx
    rep stosl

    /* Save Multiboot inputs after BSS has been cleared. */
    movl %edx, (boot_magic_save - 1b)(%ebp)
    movl %ebx, (boot_info_save - 1b)(%ebp)

    leal (__stack_top - 1b)(%ebp), %esp

    call serial_init
    leal (msg32 - 1b)(%ebp), %esi
    call serial_puts32

    /* PML4[0] -> PDPT. */
    leal (boot_pdpt - 1b)(%ebp), %eax
    orl $(PAGE_P | PAGE_RW), %eax
    movl %eax, (boot_pml4 - 1b)(%ebp)
    movl $0, (boot_pml4 + 4 - 1b)(%ebp)

    /* PDPT[0] -> PD. */
    leal (boot_pd - 1b)(%ebp), %eax
    orl $(PAGE_P | PAGE_RW), %eax
    movl %eax, (boot_pdpt - 1b)(%ebp)
    movl $0, (boot_pdpt + 4 - 1b)(%ebp)

    /* Identity map the first 1 GiB using 512 x 2 MiB pages. */
    leal (boot_pd - 1b)(%ebp), %edi
    xorl %ecx, %ecx
2:
    movl %ecx, %eax
    shll $21, %eax
    orl $(PAGE_P | PAGE_RW | PAGE_PS), %eax
    movl %eax, (%edi)
    movl $0, 4(%edi)
    addl $8, %edi
    incl %ecx
    cmpl $512, %ecx
    jne 2b

    /* Build a runtime-address GDT pseudo-descriptor. */
    movw $(gdt64_end - gdt64 - 1), (gdt64_ptr_runtime - 1b)(%ebp)
    leal (gdt64 - 1b)(%ebp), %eax
    movl %eax, (gdt64_ptr_runtime + 2 - 1b)(%ebp)
    lgdt (gdt64_ptr_runtime - 1b)(%ebp)

    movl %cr4, %eax
    orl $CR4_PAE, %eax
    movl %eax, %cr4

    leal (boot_pml4 - 1b)(%ebp), %eax
    movl %eax, %cr3

    movl $EFER_MSR, %ecx
    rdmsr
    orl $EFER_LME, %eax
    wrmsr

    movl %cr0, %eax
    orl $CR0_PG, %eax
    movl %eax, %cr0

    /* Dynamic far return: selector 0x08, runtime address of long_mode_entry. */
    pushl $0x08
    leal (long_mode_entry - 1b)(%ebp), %eax
    pushl %eax
    lret

.size _start, . - _start

.code64
.type long_mode_entry, @function
long_mode_entry:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    xorw %ax, %ax
    movw %ax, %fs
    movw %ax, %gs

    leaq __stack_top(%rip), %rsp

    /* SysV AMD64: rdi=Multiboot info pointer, rsi=Multiboot magic. */
    movl boot_info_save(%rip), %edi
    movl boot_magic_save(%rip), %esi
    xorq %rbp, %rbp
    call xloader_main

2:
    hlt
    jmp 2b

.global arch_console_putc
.type arch_console_putc, @function
arch_console_putc:
    /* ch is in %dil. */
    movb %dil, %cl
3:
    movw $0x3fd, %dx
    inb %dx, %al
    testb $0x20, %al
    jz 3b
    movw $0x3f8, %dx
    movb %cl, %al
    outb %al, %dx
    ret

.code32
serial_init:
    movw $0x3f9, %dx
    xorb %al, %al
    outb %al, %dx
    movw $0x3fb, %dx
    movb $0x80, %al
    outb %al, %dx
    movw $0x3f8, %dx
    movb $0x01, %al
    outb %al, %dx
    movw $0x3f9, %dx
    xorb %al, %al
    outb %al, %dx
    movw $0x3fb, %dx
    movb $0x03, %al
    outb %al, %dx
    movw $0x3fa, %dx
    movb $0xc7, %al
    outb %al, %dx
    movw $0x3fc, %dx
    movb $0x0b, %al
    outb %al, %dx
    ret

serial_putc32:
    pushl %eax
    movb %al, %cl
4:
    movw $0x3fd, %dx
    inb %dx, %al
    testb $0x20, %al
    jz 4b
    movw $0x3f8, %dx
    movb %cl, %al
    outb %al, %dx
    popl %eax
    ret

serial_puts32:
5:
    lodsb
    testb %al, %al
    jz 6f
    call serial_putc32
    jmp 5b
6:
    ret

.section .rodata
.align 8
msg32:
    .asciz "xloader: x86 Multiboot entry; switching to long mode\r\n"

.align 8
gdt64:
    .quad 0x0000000000000000
    .quad 0x00af9a000000ffff
    .quad 0x00af92000000ffff
gdt64_end:


.section .bss
.align 8
boot_magic_save:
    .long 0
boot_info_save:
    .long 0
gdt64_ptr_runtime:
    .skip 6

.align 4096
boot_pml4:
    .skip 4096
.align 4096
boot_pdpt:
    .skip 4096
.align 4096
boot_pd:
    .skip 4096

.align 16
stack_bottom:
    .skip 16384
__stack_top:
