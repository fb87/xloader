#include "../include/bundle.h"
#include "string.h"
#include <libfdt.h>

#define UART_BASE ((volatile uint32_t*)0x09000000)
#define UART_DR   UART_BASE[0]
#define UART_FR   UART_BASE[6]

static void uart_putc(char c) {
    while (UART_FR & (1 << 5));
    UART_DR = c;
}

static void uart_puts(const char* s) {
    while (*s) {
        if (*s == '\n')
            uart_putc('\r');
        uart_putc(*s++);
    }
}

static void uart_hex(uint64_t v) {
    static const char hex[] = "0123456789abcdef";
    char buf[20];
    int i = 0;
    buf[i++] = '0';
    buf[i++] = 'x';
    int started = 0;
    for (int s = 60; s >= 0; s -= 4) {
        int d = (v >> s) & 0xf;
        if (d || started || s == 0) {
            started = 1;
            buf[i++] = hex[d];
        }
    }
    buf[i] = 0;
    uart_puts(buf);
}

extern char _dtb_buffer[];
extern char _bundle_desc[];
extern char _stack_end[];

static void jump_to_xen(uint64_t entry, uint64_t dtb) {
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
        :
        : "r"(dtb), "r"(entry)
        : "x0", "x1", "x2", "x3");
}

static int add_module_node(void* fdt, int parent, const char* name,
                           uint64_t addr, uint64_t size,
                           const void* compat, int compat_len,
                           const char* bootargs) {
    int node = fdt_add_subnode(fdt, parent, name);
    if (node < 0)
        return node;

    fdt_setprop(fdt, node, "compatible", compat, compat_len);

    uint32_t reg[3];
    reg[0] = cpu_to_fdt32(addr >> 32);
    reg[1] = cpu_to_fdt32(addr);
    reg[2] = cpu_to_fdt32(size);
    fdt_setprop(fdt, node, "reg", reg, sizeof(reg));

    if (bootargs && *bootargs)
        fdt_setprop_string(fdt, node, "bootargs", bootargs);

    return 0;
}

static void copy_passthrough_node(void* dst_fdt, void* src_fdt,
                                  const char* path, int dst_parent) {
    int src_off = fdt_path_offset(src_fdt, path);
    if (src_off < 0) {
        uart_puts("xloader: passthrough not found: ");
        uart_puts(path);
        uart_putc('\n');
        return;
    }

    const char* name = fdt_get_name(src_fdt, src_off, NULL);
    int new_off = fdt_add_subnode(dst_fdt, dst_parent, name);
    if (new_off < 0)
        return;

    int prop;
    fdt_for_each_property_offset(prop, src_fdt, src_off) {
        int len;
        const struct fdt_property* p = fdt_get_property_by_offset(src_fdt, prop, &len);
        if (!p)
            continue;
        const char* pname = fdt_string(src_fdt, fdt32_to_cpu(p->nameoff));
        fdt_setprop(dst_fdt, new_off, pname, p->data, fdt32_to_cpu(p->len));
    }

    int sub;
    fdt_for_each_subnode(sub, src_fdt, src_off) {
        copy_passthrough_node(dst_fdt, src_fdt, "", new_off);
    }
}

void main(uint64_t dtb_ptr) {
    struct xen_bundle_desc* desc = (struct xen_bundle_desc*)&_bundle_desc;
    void* host_fdt = (void*)dtb_ptr;

    uart_puts("xloader: bundle main\n");

    if (desc->magic != XEN_BUNDLE_MAGIC || desc->version != XEN_BUNDLE_VERSION) {
        uart_puts("xloader: bad magic\n");
        goto fail;
    }

    if (!host_fdt && desc->dtb_ptr && desc->dtb_size)
        host_fdt = (void*)(uintptr_t)desc->dtb_ptr;

    if (fdt_check_header(host_fdt) != 0) {
        uart_puts("xloader: bad dtb\n");
        goto fail;
    }

    uint32_t totsize = fdt_totalsize(host_fdt);
    uart_puts("xloader: dtb size=");
    uart_hex(totsize);
    uart_putc('\n');

    void* patched_fdt = &_dtb_buffer;
    int ret = fdt_open_into(host_fdt, patched_fdt, 0x20000);
    if (ret < 0) {
        uart_puts("xloader: fdt_open_into failed\n");
        goto fail;
    }

    int chosen_off = fdt_path_offset(patched_fdt, "/chosen");
    if (chosen_off < 0) {
        chosen_off = fdt_add_subnode(patched_fdt, 0, "chosen");
        uart_puts("xloader: created chosen\n");
    }
    uart_puts("xloader: chosen_off=");
    uart_hex(chosen_off);
    uart_putc('\n');

    static const char xen_cmdline[] = "sync_console loglvl=all guest_loglvl=all dom0_mem=256M";
    fdt_setprop_string(patched_fdt, chosen_off, "xen,xen-bootargs", xen_cmdline);

    {
        int dom0_idx = (int)desc->dom0_idx;
        uart_puts("xloader: num_domains=");
        uart_hex(desc->num_domains);
        uart_puts(" dom0_idx=");
        uart_hex(dom0_idx);
        uart_putc('\n');

        if (dom0_idx >= 0 && dom0_idx < (int)desc->num_domains) {
            struct xen_domain_desc* d = &desc->domains[dom0_idx];
            if (d->num_passthrough || d->passthrough_off) {
                uart_puts("xloader: dom0 passthrough unsupported\n");
                goto fail;
            }
            if (d->kernel_addr && d->kernel_size) {
                uart_puts("xloader: add dom0 kernel\n");
                static const char compat_kernel[] = "xen,multiboot-module";
                add_module_node(patched_fdt, chosen_off, "module@0",
                                d->kernel_addr, d->kernel_size,
                                compat_kernel, sizeof(compat_kernel),
                                d->cmdline[0] ? d->cmdline : 0);
            }
            if (d->initrd_addr && d->initrd_size) {
                uart_puts("xloader: add dom0 initrd\n");
                static const char compat_initrd[] = "xen,multiboot-module";
                add_module_node(patched_fdt, chosen_off, "module@1",
                                d->initrd_addr, d->initrd_size,
                                compat_initrd, sizeof(compat_initrd), 0);
            }
        }

        for (int i = 0; i < (int)desc->num_domains; i++) {
            if (i == dom0_idx)
                continue;
            struct xen_domain_desc* d = &desc->domains[i];
            if (!d->kernel_addr && !d->kernel_size)
                continue;
            uart_puts("xloader: add domain@");
            uart_hex(i);
            uart_putc('\n');
            uint64_t mem_kb = d->memory_kb ? d->memory_kb : 131072;
            uart_puts("xloader: domain memory=");
            uart_hex(mem_kb);
            uart_putc('\n');

            char name[32];
            fmt_node_name(name, sizeof(name), "domain", i);
            int dom_node = fdt_add_subnode(patched_fdt, chosen_off, name);
            if (dom_node < 0)
                continue;

            fdt_setprop_string(patched_fdt, dom_node, "compatible", "xen,domain");

            uint32_t ac = cpu_to_fdt32(2U);
            fdt_setprop(patched_fdt, dom_node, "#address-cells", &ac, 4);
            uint32_t sc = cpu_to_fdt32(1U);
            fdt_setprop(patched_fdt, dom_node, "#size-cells", &sc, 4);

            uint32_t cpus = cpu_to_fdt32(1U);
            fdt_setprop(patched_fdt, dom_node, "cpus", &cpus, 4);

            uint32_t mem[2];
            mem[0] = cpu_to_fdt32(mem_kb >> 32);
            mem[1] = cpu_to_fdt32(mem_kb);
            fdt_setprop(patched_fdt, dom_node, "memory", mem, 8);

            fdt_setprop_empty(patched_fdt, dom_node, "vpl011");
            fdt_setprop_string(patched_fdt, dom_node, "xen,enhanced", "no-xenstore");

            if (d->cmdline[0])
                fdt_setprop_string(patched_fdt, dom_node, "bootargs", d->cmdline);

            int mi = 0;
            if (d->kernel_addr && d->kernel_size) {
                char mname[32];
                fmt_node_name(mname, sizeof(mname), "module", mi++);
                static const char compat_kernel[] = "multiboot,module\0multiboot,kernel";
                add_module_node(patched_fdt, dom_node, mname,
                                d->kernel_addr, d->kernel_size,
                                compat_kernel, sizeof(compat_kernel),
                                d->cmdline[0] ? d->cmdline : 0);
            }
            if (d->initrd_addr && d->initrd_size) {
                char mname[32];
                fmt_node_name(mname, sizeof(mname), "module", mi++);
                static const char compat_ramdisk[] = "multiboot,module\0multiboot,ramdisk";
                add_module_node(patched_fdt, dom_node, mname,
                                d->initrd_addr, d->initrd_size,
                                compat_ramdisk, sizeof(compat_ramdisk), 0);
            }

            const char* paths[XEN_BUNDLE_MAX_PASSTHROUGH];
            int np = 0;
            if (d->num_passthrough > XEN_BUNDLE_MAX_PASSTHROUGH)
                goto fail;
            if (d->num_passthrough) {
                if (!d->passthrough_off)
                    goto fail;
                const char* p = (const char*)desc + d->passthrough_off;
                for (uint32_t pi = 0; pi < d->num_passthrough; pi++) {
                    paths[np++] = p;
                    uart_puts("xloader: passthrough ");
                    uart_puts(p);
                    uart_putc('\n');
                    p += strlen(p) + 1;
                }
            }
            for (int pi = 0; pi < np; pi++)
                copy_passthrough_node(patched_fdt, host_fdt, paths[pi], dom_node);
        }
    }

    fdt_pack(patched_fdt);

    uint32_t final_size = fdt_totalsize(patched_fdt);
    uart_puts("xloader: final_size=");
    uart_hex(final_size);
    uart_putc('\n');
    uint64_t dtb_final = (uint64_t)_stack_end;
    dtb_final = (dtb_final + 63) & ~63ULL;
    uart_puts("xloader: dtb_final=");
    uart_hex(dtb_final);
    uart_puts(" xen_entry=");
    uart_hex(desc->xen_entry);
    uart_putc('\n');
    memcpy((void*)dtb_final, patched_fdt, final_size);

    uart_puts("xloader: jumping to Xen\n");
    jump_to_xen(desc->xen_entry, dtb_final);

fail:
    uart_puts("xloader: FAIL\n");
    for (;;)
        asm volatile("wfi");
}
