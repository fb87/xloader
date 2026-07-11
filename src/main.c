#include "../include/bundle.h"
#include "string.h"
#include <libfdt.h>
#include <stdarg.h>

#define UART_BASE ((volatile uint32_t*)0x09000000)
#define UART_DR   UART_BASE[0]
#define UART_FR   UART_BASE[6]

static void uart_putc(char c) {
    while (UART_FR & (1 << 5));
    UART_DR = c;
}

static void uart_puts(const char* s) {
    while (*s) {
        if (*s == '\n') uart_putc('\r');
        uart_putc(*s++);
    }
}

static void printf(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    for (const char* p = fmt; *p; p++) {
        if (*p != '%') {
            if (*p == '\n') uart_putc('\r');
            uart_putc(*p);
            continue;
        }
        switch (*++p) {
        case 's': uart_puts(va_arg(ap, const char*)); break;
        case 'd': {
            int v = va_arg(ap, int);
            char buf[12], tmp[12];
            int i = 0, ti = 0;
            if (v < 0) { buf[i++] = '-'; v = -v; }
            if (v == 0) tmp[ti++] = '0';
            while (v) { tmp[ti++] = '0' + v % 10; v /= 10; }
            while (ti) buf[i++] = tmp[--ti];
            buf[i] = 0;
            uart_puts(buf);
            break;
        }
        case 'x': {
            unsigned int v = va_arg(ap, unsigned int);
            char buf[12];
            int i = 0, started = 0;
            for (int s = 28; s >= 0; s -= 4) {
                int d = (v >> s) & 0xf;
                if (d || started || s == 0) { started = 1; buf[i++] = "0123456789abcdef"[d]; }
            }
            buf[i] = 0;
            uart_puts(buf);
            break;
        }
        case 'l':
            if (*++p == 'x') {
                unsigned long v = va_arg(ap, unsigned long);
                char buf[20];
                int i = 0, started = 0;
                for (int s = 60; s >= 0; s -= 4) {
                    int d = (v >> s) & 0xf;
                    if (d || started || s == 0) { started = 1; buf[i++] = "0123456789abcdef"[d]; }
                }
                buf[i] = 0;
                uart_puts(buf);
            }
            break;
        case '%': uart_putc('%'); break;
        default: uart_putc('%'); uart_putc(*p); break;
        }
    }
    va_end(ap);
}

#define DTB_BUF_SIZE 0x200000
#define PT_BUF_OFFSET 0x10000

extern char _dtb_buffer[];
extern char _xloader_end[];

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
    if (node < 0) return node;
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


static void copy_node_props(void* dst_fdt, int dst_off,
                            void* src_fdt, int src_off) {
    int prop;
    fdt_for_each_property_offset(prop, src_fdt, src_off) {
        int len;
        const struct fdt_property* p = fdt_get_property_by_offset(src_fdt, prop, &len);
        if (!p) continue;
        const char* pname = fdt_string(src_fdt, fdt32_to_cpu(p->nameoff));
        fdt_setprop(dst_fdt, dst_off, pname, p->data, fdt32_to_cpu(p->len));
    }
    int sub;
    fdt_for_each_subnode(sub, src_fdt, src_off) {
        const char* sname = fdt_get_name(src_fdt, sub, NULL);
        int new_sub = fdt_add_subnode(dst_fdt, dst_off, sname);
        if (new_sub >= 0)
            copy_node_props(dst_fdt, new_sub, src_fdt, sub);
    }
}


void main(uint64_t dtb_ptr) {
    uint64_t desc_off = ((uint64_t)&_xloader_end + 63) & ~63ULL;
    struct xen_bundle_desc* desc = (struct xen_bundle_desc*)desc_off;
    void* host_fdt = (void*)dtb_ptr;

    printf("(LDR) bundle main\n");

    if (desc->magic != XEN_BUNDLE_MAGIC || desc->version != XEN_BUNDLE_VERSION) {
        printf("(LDR) bad magic\n");
        goto fail;
    }

    if (!host_fdt && desc->dtb_ptr && desc->dtb_size)
        host_fdt = (void*)(uintptr_t)desc->dtb_ptr;

    if (fdt_check_header(host_fdt) != 0) {
        printf("(LDR) bad dtb\n");
        goto fail;
    }

    uint32_t totsize = fdt_totalsize(host_fdt);
    printf("(LDR) dtb size=0x%x\n", totsize);

    void* patched_fdt = &_dtb_buffer;
    int ret = fdt_open_into(host_fdt, patched_fdt, DTB_BUF_SIZE);
    if (ret < 0) {
        printf("(LDR) fdt_open_into failed\n");
        goto fail;
    }

    int chosen_off = fdt_path_offset(patched_fdt, "/chosen");
    if (chosen_off < 0) {
        chosen_off = fdt_add_subnode(patched_fdt, 0, "chosen");
        printf("(LDR) created chosen\n");
    }
    printf("(LDR) chosen_off=0x%x\n", chosen_off);

    static const char xen_cmdline[] = "sync_console loglvl=all guest_loglvl=all dom0_mem=256M";
    fdt_setprop_string(patched_fdt, chosen_off, "xen,xen-bootargs", xen_cmdline);

    {
        int dom0_idx = (int)desc->dom0_idx;
        printf("(LDR) num_domains=%d dom0_idx=0x%x\n", (int)desc->num_domains, dom0_idx);

        if (dom0_idx >= 0 && dom0_idx < (int)desc->num_domains) {
            struct xen_domain_desc* d = &desc->domains[dom0_idx];
            if (d->num_passthrough || d->passthrough_off) {
                printf("(LDR) dom0 passthrough unsupported\n");
                goto fail;
            }
            if (d->kernel_addr && d->kernel_size) {
                printf("(LDR) add dom0 kernel\n");
                static const char compat_kernel[] = "xen,multiboot-module";
                add_module_node(patched_fdt, chosen_off, "module@0",
                                d->kernel_addr, d->kernel_size,
                                compat_kernel, sizeof(compat_kernel),
                                d->cmdline[0] ? d->cmdline : 0);
            }
            if (d->initrd_addr && d->initrd_size) {
                printf("(LDR) add dom0 initrd\n");
                static const char compat_initrd[] = "xen,multiboot-module";
                add_module_node(patched_fdt, chosen_off, "module@1",
                                d->initrd_addr, d->initrd_size,
                                compat_initrd, sizeof(compat_initrd), 0);
            }
        }

        for (int i = 0; i < (int)desc->num_domains; i++) {
            if (i == dom0_idx) continue;
            struct xen_domain_desc* d = &desc->domains[i];
            if (!d->kernel_addr && !d->kernel_size) continue;
            printf("(LDR) add domain@%d\n", i);
            uint64_t mem_kb = d->memory_kb ? d->memory_kb : 131072;
            printf("(LDR) domain memory=0x%lx\n", mem_kb);

            char name[32];
            fmt_node_name(name, sizeof(name), "domain", i);
            int dom_node = fdt_add_subnode(patched_fdt, chosen_off, name);
            if (dom_node < 0) continue;

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
                static const char compat_kernel[] = "multiboot,kernel\0multiboot,module";
                add_module_node(patched_fdt, dom_node, mname,
                                d->kernel_addr, d->kernel_size,
                                compat_kernel, sizeof(compat_kernel),
                                d->cmdline[0] ? d->cmdline : 0);
            }
            if (d->initrd_addr && d->initrd_size) {
                char mname[32];
                fmt_node_name(mname, sizeof(mname), "module", mi++);
                static const char compat_ramdisk[] = "multiboot,ramdisk\0multiboot,module";
                add_module_node(patched_fdt, dom_node, mname,
                                d->initrd_addr, d->initrd_size,
                                compat_ramdisk, sizeof(compat_ramdisk), 0);
            }
            if (d->num_passthrough && d->passthrough_off) {
                if (d->num_passthrough > XEN_BUNDLE_MAX_PASSTHROUGH)
                    goto fail;

                void* pt_buf = (void*)_dtb_buffer + PT_BUF_OFFSET;
                int pt_ret = fdt_create_empty_tree(pt_buf, 0x10000);
                if (pt_ret < 0) { printf("(LDR) pt create fail\n"); goto fail; }

                int pt_cont = fdt_add_subnode(pt_buf, 0, "passthrough");
                if (pt_cont < 0) { printf("(LDR) pt container fail\n"); goto fail; }

                const char* p = (const char*)desc + d->passthrough_off;
                int copied = 0;
                for (uint32_t pi = 0; pi < d->num_passthrough; pi++) {
                    int src_off = fdt_path_offset(host_fdt, p);
                    if (src_off >= 0) {
                        const char* nm = fdt_get_name(host_fdt, src_off, NULL);
                        int new_off = fdt_add_subnode(pt_buf, pt_cont, nm);
                        if (new_off >= 0) {
                            copy_node_props(pt_buf, new_off, host_fdt, src_off);
                        }
                        copied = 1;
                        printf("(LDR) passthrough %s\n", p);
                    }
                    p += strlen(p) + 1;
                }

                if (copied) {
                    fdt_pack(pt_buf);
                    char mname[32];
                    fmt_node_name(mname, sizeof(mname), "module", mi++);
                    static const char compat_pt[] = "multiboot,device-tree\0multiboot,module";
                    add_module_node(patched_fdt, dom_node, mname,
                                    (uint64_t)pt_buf, fdt_totalsize(pt_buf),
                                    compat_pt, sizeof(compat_pt), 0);
                    printf("(LDR) passthrough dtb @ 0x%lx size 0x%x\n",
                           (uint64_t)pt_buf, fdt_totalsize(pt_buf));
                }
            }
        }
    }

    fdt_pack(patched_fdt);
    uint32_t final_size = fdt_totalsize(patched_fdt);
    uint64_t dtb_final = (uint64_t)&_dtb_buffer;
    printf("(LDR) dtb_final=0x%lx size=0x%x xen_entry=0x%lx\n",
           dtb_final, final_size, desc->xen_entry);

    printf("(LDR) jumping to Xen\n");
    jump_to_xen(desc->xen_entry, dtb_final);

fail:
    printf("(LDR) FAIL\n");
    for (;;)
        asm volatile("wfi");
}
