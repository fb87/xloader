.section .text.arch_enter_xen, "ax"
.align 4
.global arch_enter_xen
.type arch_enter_xen, %function

/*
 * void arch_enter_xen(uintptr_t entry, uintptr_t dtb) noreturn
 *
 * AArch64 Xen boot contract used by xloader:
 *   x0 = physical address of host DTB
 *   x1..x3 = 0
 *   branch to Xen physical entry point
 *
 * xloader inherits EL2/MMU/cache state from the previous boot stage and does
 * not enable the MMU.  M3 uses full-system barriers before handoff; hardware
 * cache-state normalization remains an explicit later hardening item.
 */
arch_enter_xen:
    mov x4, x0
    mov x0, x1
    mov x1, xzr
    mov x2, xzr
    mov x3, xzr
    dsb sy
    isb
    br x4
.size arch_enter_xen, . - arch_enter_xen
