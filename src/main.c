#include "../include/bundle.h"
#include "dtb.h"
#include "string.h"

#define UART_BASE ((volatile uint32_t*)0x09000000)
#define UART_DR   UART_BASE[0]
#define UART_FR   UART_BASE[6]

static void uart_putc(char c) {
    while (UART_FR & (1 << 5));
    UART_DR = c;
}

static void uart_puts(const char *s) {
    while (*s) {
        if (*s == '\n') uart_putc('\r');
        uart_putc(*s++);
    }
}

static void uart_hex(uint64_t v) {
    static const char hex[] = "0123456789abcdef";
    char buf[20];
    int i = 0;
    buf[i++] = '0'; buf[i++] = 'x';
    int started = 0;
    for (int s = 60; s >= 0; s -= 4) {
        int d = (v >> s) & 0xf;
        if (d || started || s == 0) { started = 1; buf[i++] = hex[d]; }
    }
    buf[i] = 0;
    uart_puts(buf);
}

extern char _dtb_buffer[];
extern char _bundle_desc[];
extern char _stack_end[];

static void jump_to_xen(uint64_t entry, uint64_t dtb) {
    uint64_t addr = dtb;
    asm volatile(
        "dc civac, %0\n"
        "dsb sy\n"
        "ic iallu\n"
        "dsb sy\n"
        "isb\n"
        "mov x0, %0\n"
        "mov x1, xzr\n"
        "mov x2, xzr\n"
        "mov x3, xzr\n"
        "br %1\n"
        :: "r"(addr), "r"(entry)
        : "x0", "x1", "x2", "x3"
    );
}

void main(uint64_t dtb_ptr) {
    struct xen_bundle_desc *desc = (struct xen_bundle_desc*)&_bundle_desc;
    void *host_fdt = (void*)dtb_ptr;
    void *patched_fdt = (void*)&_dtb_buffer;

    uart_puts("xloader: bundle main\n");

    if (desc->magic != XEN_BUNDLE_MAGIC || desc->version != XEN_BUNDLE_VERSION) {
        uart_puts("xloader: bad magic\n");
        goto fail;
    }

    if (!host_fdt && desc->dtb_ptr && desc->dtb_size)
        host_fdt = (void*)(uintptr_t)desc->dtb_ptr;

    if (dtb_validate(host_fdt) < 0) {
        uart_puts("xloader: bad dtb\n");
        goto fail;
    }

    uint32_t totsize = dtb_rd32(&((struct fdt_header*)host_fdt)->totalsize);
    uart_puts("xloader: dtb size="); uart_hex(totsize); uart_putc('\n');
    if (totsize > 0x20000 - 0x1000)
        goto fail;

    memcpy(patched_fdt, host_fdt, totsize);

    int chosen_off = dtb_find_chosen(patched_fdt);
    if (chosen_off < 0) {
        uart_puts("xloader: no chosen, creating\n");
        chosen_off = dtb_create_chosen(patched_fdt);
    }
    uart_puts("xloader: chosen_off="); uart_hex(chosen_off); uart_putc('\n');

    if (chosen_off < 0)
        goto fail;

    {
        int ne = node_end(patched_fdt, chosen_off);
        if (ne > 0) {
            char pbuf[128];
            int po = 0;
            int no = dtb_add_string(patched_fdt, "bootargs");
            static const char xen_cmdline[] = "sync_console dom0_mem=256M";
            dtb_wr32(pbuf + po, FDT_PROP); po += 4;
            dtb_wr32(pbuf + po, sizeof(xen_cmdline)); po += 4;
            dtb_wr32(pbuf + po, no); po += 4;
            memcpy(pbuf + po, xen_cmdline, sizeof(xen_cmdline));
            po += sizeof(xen_cmdline);
            while (po & 3) pbuf[po++] = 0;
            dtb_insert(patched_fdt, ne, po);
            memcpy(patched_fdt + ne, pbuf, po);
        }
    }

    {
        int dom0_idx = (int)desc->dom0_idx;
        uart_puts("xloader: num_domains="); uart_hex(desc->num_domains);
        uart_puts(" dom0_idx="); uart_hex(dom0_idx); uart_putc('\n');
        if (dom0_idx >= 0 && dom0_idx < (int)desc->num_domains) {
            struct xen_domain_desc *d = &desc->domains[dom0_idx];
            if (d->kernel_addr && d->kernel_size) {
                uart_puts("xloader: add dom0 kernel\n");
                dtb_add_module(patched_fdt, chosen_off,
                               d->kernel_addr, d->kernel_size, "module@0",
                               d->cmdline[0] ? d->cmdline : 0,
                               0);
            }
            if (d->initrd_addr && d->initrd_size) {
                uart_puts("xloader: add dom0 initrd\n");
                dtb_add_module(patched_fdt, chosen_off,
                               d->initrd_addr, d->initrd_size, "module@1",
                               0, 0);
            }
        }

        for (int i = 0; i < (int)desc->num_domains; i++) {
            if (i == dom0_idx) continue;
            struct xen_domain_desc *d = &desc->domains[i];
            if (!d->kernel_addr && !d->kernel_size) continue;
            uart_puts("xloader: add domain@"); uart_hex(i); uart_putc('\n');
            uint64_t mem_kb = d->memory_kb ? d->memory_kb : 131072;
            uart_puts("xloader: domain memory="); uart_hex(mem_kb); uart_putc('\n');
            dtb_add_domain(patched_fdt, chosen_off, host_fdt,
                           d->kernel_addr, d->kernel_size,
                           d->initrd_addr, d->initrd_size,
                           d->cmdline[0] ? d->cmdline : 0,
                           mem_kb, i, 0, 0, 0, 0);
        }
    }

    dtb_finalize(patched_fdt);

    uint32_t final_size = dtb_rd32(&((struct fdt_header*)patched_fdt)->totalsize);
    uart_puts("xloader: final_size="); uart_hex(final_size); uart_putc('\n');
    uint64_t dtb_final = (uint64_t)_stack_end;
    dtb_final = (dtb_final + 63) & ~63ULL;
    uart_puts("xloader: dtb_final="); uart_hex(dtb_final);
    uart_puts(" xen_entry="); uart_hex(desc->xen_entry); uart_putc('\n');
    memcpy((void*)dtb_final, patched_fdt, final_size);

    uart_puts("xloader: jumping to Xen\n");
    jump_to_xen(desc->xen_entry, dtb_final);

fail:
    uart_puts("xloader: FAIL\n");
    for (;;)
        asm volatile("wfi");
}
