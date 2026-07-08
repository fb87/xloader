#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <libgen.h>
#include <unistd.h>
#include <sys/stat.h>

#define MAX_DOMAINS 16
#define MAX_PASSTHROUGH 32
#define PAGE_SIZE 0x10000
#define MAX_CMDLINE 256

struct payload {
    unsigned char *data;
    int size;
    uint64_t addr;
    const char *path;
};

struct domain_cfg {
    const char *kernel_path;
    const char *initrd_path;
    const char *cmdline;
    const char *passthrough[MAX_PASSTHROUGH];
    int num_passthrough;
    int is_dom0;
};

static unsigned char *read_file(const char *path, int *size) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return NULL; }
    struct stat st;
    stat(path, &st);
    *size = st.st_size;
    unsigned char *buf = malloc(*size);
    if (!buf) { fclose(f); return NULL; }
    fread(buf, 1, *size, f);
    fclose(f);
    return buf;
}

static uint64_t elf_get_entry(const char *path) {
    int sz;
    unsigned char *elf = read_file(path, &sz);
    if (!elf || sz < 64) return 0;

    if (elf[0] != 0x7f || elf[1] != 'E' || elf[2] != 'L' || elf[3] != 'F')
        return 0;
    if (elf[4] != 2) { free(elf); return 0; }

    uint64_t entry;
    memcpy(&entry, elf + 24, 8);
    free(elf);
    return entry;
}

__attribute__((unused)) static uint64_t elf_get_load_addr(const char *path) {
    int sz;
    unsigned char *elf = read_file(path, &sz);
    if (!elf || sz < 64) return 0;

    if (elf[0] != 0x7f || elf[1] != 'E' || elf[2] != 'L' || elf[3] != 'F')
        return 0;
    if (elf[4] != 2) { free(elf); return 0; }

    uint64_t phoff;
    uint16_t phnum, phentsize;
    memcpy(&phoff, elf + 32, 8);
    memcpy(&phnum, elf + 56, 2);
    memcpy(&phentsize, elf + 54, 2);

    for (int i = 0; i < phnum; i++) {
        uint32_t type;
        memcpy(&type, elf + phoff + i * phentsize, 4);
        if (type == 1) { /* PT_LOAD */
            uint64_t vaddr, memsz;
            memcpy(&vaddr, elf + phoff + i * phentsize + 16, 8);
            memcpy(&memsz, elf + phoff + i * phentsize + 48, 8);
            free(elf);
            return vaddr;
        }
    }
    free(elf);
    return 0;
}

static uint64_t elf_get_end_addr(const char *path) {
    int sz;
    unsigned char *elf = read_file(path, &sz);
    if (!elf || sz < 64) return 0;

    if (elf[0] != 0x7f || elf[1] != 'E' || elf[2] != 'L' || elf[3] != 'F')
        return 0;

    uint64_t phoff;
    uint16_t phnum, phentsize;
    memcpy(&phoff, elf + 32, 8);
    memcpy(&phnum, elf + 56, 2);
    memcpy(&phentsize, elf + 54, 2);

    uint64_t end = 0;
    for (int i = 0; i < phnum; i++) {
        uint32_t type;
        memcpy(&type, elf + phoff + i * phentsize, 4);
        if (type == 1) {
            uint64_t vaddr, memsz;
            memcpy(&vaddr, elf + phoff + i * phentsize + 16, 8);
            memcpy(&memsz, elf + phoff + i * phentsize + 48, 8);
            uint64_t seg_end = vaddr + memsz;
            if (seg_end > end) end = seg_end;
        }
    }
    free(elf);
    return end;
}

static uint64_t align_page(uint64_t addr) {
    return (addr + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
}

static void parse_domain_str(const char *str, struct domain_cfg *cfg) {
    memset(cfg, 0, sizeof(*cfg));
    char *buf = strdup(str);
    if (!buf) return;

    char *save;
    for (char *tok = strtok_r(buf, ";", &save); tok; tok = strtok_r(NULL, ";", &save)) {
        while (*tok == ' ') tok++;
        char *eq = strchr(tok, '=');
        if (!eq) continue;
        *eq = 0;
        const char *key = tok;
        const char *val = eq + 1;

        if (!strcmp(key, "kernel"))
            cfg->kernel_path = strdup(val);
        else if (!strcmp(key, "initrd"))
            cfg->initrd_path = strdup(val);
        else if (!strcmp(key, "cmdline"))
            cfg->cmdline = strdup(val);
        else if (!strcmp(key, "passthrough")) {
            char *pdup = strdup(val);
            char *psave;
            for (char *p = strtok_r(pdup, ",", &psave); p && cfg->num_passthrough < MAX_PASSTHROUGH;
                 p = strtok_r(NULL, ",", &psave)) {
                while (*p == ' ') p++;
                cfg->passthrough[cfg->num_passthrough++] = strdup(p);
            }
            free(pdup);
        }
    }
    free(buf);
}

static int write_payloads_s(FILE *f, uint64_t base, uint64_t *payload_addrs,
                            const char **payload_names, int num_payloads,
                            struct domain_cfg *domains, int num_domains,
                            int dom0_idx, uint64_t xen_entry,
                            uint64_t desc_addr)
{
    fprintf(f, ".section .rodata.bundle_desc, \"a\"\n");
    fprintf(f, ".balign 8\n");
    fprintf(f, ".globl _bundle_desc\n");
    fprintf(f, "_bundle_desc:\n");

    fprintf(f, "\t.quad 0x58454E42554E444CULL\n");  /* magic */
    fprintf(f, "\t.quad 1\n");                        /* version */
    fprintf(f, "\t.quad 0x%lx\n", base);              /* bundle_addr */
    fprintf(f, "\t.quad 0x%lx\n", payload_addrs[0]);  /* xen_addr */
    fprintf(f, "\t.quad 0x%x\n", 0);                  /* xen_size placeholder */
    fprintf(f, "\t.quad 0x%lx\n", xen_entry);          /* xen_entry */
    fprintf(f, "\t.quad %d\n", num_domains);           /* num_domains */
    fprintf(f, "\t.quad %d\n", dom0_idx);              /* dom0_idx */

    int pi = 1;

    for (int i = 0; i < num_domains; i++) {
        struct domain_cfg *d = &domains[i];
        uint64_t kaddr = 0, ksize = 0;
        uint64_t iaddr = 0, isize = 0;

        if (d->kernel_path) {
            kaddr = payload_addrs[pi];
            pi++;
        }
        if (d->initrd_path) {
            iaddr = payload_addrs[pi];
            pi++;
        }

        fprintf(f, "\t.quad 0x%lx\n", kaddr);    /* kernel_addr */
        fprintf(f, "\t.quad 0x%lx\n", ksize);     /* kernel_size - FIXED BELOW */
        fprintf(f, "\t.quad 0x%lx\n", iaddr);     /* initrd_addr */
        fprintf(f, "\t.quad 0x%lx\n", isize);     /* initrd_size - FIXED BELOW */
        fprintf(f, "\t.quad 0\n");                 /* dtb_addr */
        fprintf(f, "\t.quad 0\n");                 /* dtb_size */
        fprintf(f, "\t.fill 256,1,0\n");           /* cmdline */

        int npt = d->num_passthrough;
        fprintf(f, "\t.long %d\n", npt);            /* num_passthrough */
        fprintf(f, "\t.long 0\n");                  /* passthrough_off */
        fprintf(f, "\t.long 0\n");                  /* num_passthrough_strings */
        fprintf(f, "\t.long 0\n");                  /* passthrough_strings_off */
    }

    fprintf(f, ".globl _passthrough_paths\n");
    fprintf(f, "_passthrough_paths:\n");
    for (int i = 0; i < num_domains; i++) {
        for (int j = 0; j < domains[i].num_passthrough; j++) {
            fprintf(f, "\t.asciz \"%s\"\n", domains[i].passthrough[j]);
        }
    }
    fprintf(f, "\t.byte 0\n");

    pi = 1;
    for (int i = 0; i < num_domains; i++) {
        if (domains[i].kernel_path) {
            fprintf(f, ".section .payload_%d_kernel, \"ax\"\n", i);
            fprintf(f, ".globl _payload_%d_kernel_start\n", i);
            fprintf(f, "_payload_%d_kernel_start:\n", i);
            fprintf(f, ".incbin \"%s\"\n", domains[i].kernel_path);
            fprintf(f, "_payload_%d_kernel_end:\n", i);
            fprintf(f, ".globl _payload_%d_kernel_size\n", i);
            fprintf(f, "_payload_%d_kernel_size:\n", i);
            fprintf(f, ".quad _payload_%d_kernel_end - _payload_%d_kernel_start\n", i, i);
            pi++;
        }
        if (domains[i].initrd_path) {
            fprintf(f, ".section .payload_%d_initrd, \"ax\"\n", i);
            fprintf(f, ".globl _payload_%d_initrd_start\n", i);
            fprintf(f, "_payload_%d_initrd_start:\n", i);
            fprintf(f, ".incbin \"%s\"\n", domains[i].initrd_path);
            fprintf(f, "_payload_%d_initrd_end:\n", i);
            fprintf(f, ".globl _payload_%d_initrd_size\n", i);
            fprintf(f, "_payload_%d_initrd_size:\n", i);
            fprintf(f, ".quad _payload_%d_initrd_end - _payload_%d_initrd_start\n", i, i);
            pi++;
        }
    }

    fprintf(f, ".section .rodata.xen_entry, \"a\"\n");
    fprintf(f, ".globl _xen_entry\n");
    fprintf(f, "_xen_entry:\n");
    fprintf(f, "\t.quad 0x%lx\n", xen_entry);

    return 0;
}

static int write_linker_script(FILE *f, uint64_t base, uint64_t loader_end,
                               uint64_t *payload_addrs, int num_payloads,
                               struct domain_cfg *domains, int num_domains,
                               int dom0_idx, int desc_size)
{
    fprintf(f, "OUTPUT_FORMAT(elf64-littleaarch64)\n");
    fprintf(f, "OUTPUT_ARCH(aarch64)\n");
    fprintf(f, "ENTRY(_start)\n\n");

    fprintf(f, "PHDRS\n");
    fprintf(f, "{\n");
    fprintf(f, "  text PT_LOAD;\n");
    fprintf(f, "  rodata PT_LOAD;\n");
    fprintf(f, "  data PT_LOAD;\n");
    fprintf(f, "  bss PT_LOAD;\n");
    for (int i = 0; i < num_domains * 2 + 1; i++)
        fprintf(f, "  payload_%d PT_LOAD;\n", i);
    fprintf(f, "}\n\n");

    fprintf(f, "SECTIONS\n{\n");
    fprintf(f, "  . = 0x%lx;\n\n", base);

    fprintf(f, "  .text : { *(.text.entry) *(.text*) } :text\n");
    fprintf(f, "  .rodata : { *(.rodata*) } :rodata\n");
    fprintf(f, "  .data : { *(.data*) } :data\n");

    fprintf(f, "  .bss : ALIGN(16) {\n");
    fprintf(f, "    _bss_start = .;\n");
    fprintf(f, "    *(.bss*); *(COMMON);\n");
    fprintf(f, "    . = ALIGN(16);\n");
    fprintf(f, "    _bss_end = .;\n");
    fprintf(f, "    . = ALIGN(4096);\n");
    fprintf(f, "    _dtb_buffer = .;\n");
    fprintf(f, "    . = . + 0x20000;\n");
    fprintf(f, "  } :bss\n\n");

    fprintf(f, "  _stack_start = .;\n");
    fprintf(f, "  . = . + 0x4000;\n");
    fprintf(f, "  _stack_end = .;\n\n");

    int pi = 1;
    for (int i = 0; i < num_domains; i++) {
        struct domain_cfg *d = &domains[i];
        if (d->kernel_path) {
            fprintf(f, "  .payload_%d_kernel ", i);
            fprintf(f, "0x%lx : { *(.payload_%d_kernel) } :payload_%d\n",
                    payload_addrs[pi], i, pi);
            pi++;
        }
        if (d->initrd_path) {
            fprintf(f, "  .payload_%d_initrd ", i);
            fprintf(f, "0x%lx : { *(.payload_%d_initrd) } :payload_%d\n",
                    payload_addrs[pi], i, pi);
            pi++;
        }
    }

    fprintf(f, "}\n");
    return 0;
}

int main(int argc, char **argv) {
    const char *base_str = "0x40000000";
    const char *xen_path = NULL;
    const char *output_path = "bundle.elf";
    const char *loader_objects[64];
    int num_loader_objects = 0;
    struct domain_cfg domains[MAX_DOMAINS];
    int num_domains = 0;
    int dom0_idx = -1;

    memset(domains, 0, sizeof(domains));

    for (int i = 1; i < argc; i++) {
        if (!strncmp(argv[i], "--base=", 7))
            base_str = argv[i] + 7;
        else if (!strncmp(argv[i], "--xen=", 6))
            xen_path = argv[i] + 6;
        else if (!strncmp(argv[i], "--dom0=", 7)) {
            parse_domain_str(argv[i] + 7, &domains[num_domains]);
            domains[num_domains].is_dom0 = 1;
            dom0_idx = num_domains;
            num_domains++;
        } else if (!strncmp(argv[i], "--domU=", 7)) {
            parse_domain_str(argv[i] + 7, &domains[num_domains]);
            domains[num_domains].is_dom0 = 0;
            num_domains++;
        } else if (!strncmp(argv[i], "-o", 2)) {
            if (i + 1 < argc) output_path = argv[++i];
        } else if (argv[i][0] != '-') {
            if (num_loader_objects < 64)
                loader_objects[num_loader_objects++] = argv[i];
        }
    }

    if (!xen_path) {
        fprintf(stderr, "error: --xen=<path> required\n");
        return 1;
    }
    if (num_domains == 0) {
        fprintf(stderr, "error: at least one --dom0= or --domU= required\n");
        return 1;
    }

    uint64_t base;
    sscanf(base_str, "0x%lx", &base);

    uint64_t xen_entry = elf_get_entry(xen_path);
    if (!xen_entry) {
        fprintf(stderr, "warning: could not read Xen ELF entry, using load addr\n");
        xen_entry = base + 0x20000;
    }

    struct payload payloads[MAX_DOMAINS * 2 + 1];
    int num_payloads = 0;

    int ps = 0; read_file(xen_path, &ps);
    if (ps <= 0) { fprintf(stderr, "error: bad xen file\n"); return 1; }

    payloads[0].data = NULL;
    payloads[0].size = ps;
    payloads[0].addr = 0;
    payloads[0].path = xen_path;
    num_payloads = 1;

    for (int i = 0; i < num_domains; i++) {
        struct domain_cfg *d = &domains[i];
        if (d->kernel_path) {
            payloads[num_payloads].data = NULL;
            payloads[num_payloads].size = 0;
            payloads[num_payloads].path = d->kernel_path;
            num_payloads++;
        }
        if (d->initrd_path) {
            payloads[num_payloads].data = NULL;
            payloads[num_payloads].size = 0;
            payloads[num_payloads].path = d->initrd_path;
            num_payloads++;
        }
    }

    for (int i = 0; i < num_payloads; i++) {
        if (payloads[i].path) {
            payloads[i].data = read_file(payloads[i].path, &payloads[i].size);
            if (!payloads[i].data) {
                fprintf(stderr, "error: can't read %s\n", payloads[i].path);
                return 1;
            }
        }
    }

    const char *build_dir = "build";
    mkdir(build_dir, 0755);

    char prelink_lds[128];
    snprintf(prelink_lds, sizeof(prelink_lds), "%s/prelink.lds", build_dir);
    {
        FILE *pf = fopen(prelink_lds, "w");
        fprintf(pf, "OUTPUT_FORMAT(elf64-littleaarch64)\n");
        fprintf(pf, "OUTPUT_ARCH(aarch64)\n");
        fprintf(pf, "ENTRY(_start)\n");
        fprintf(pf, "SECTIONS {\n");
        fprintf(pf, "  . = 0x%lx;\n", base);
        fprintf(pf, "  .text : { *(.text*) *(.text.entry) }\n");
        fprintf(pf, "  .rodata : { *(.rodata*) }\n");
        fprintf(pf, "  .data : { *(.data*) }\n");
        fprintf(pf, "  .bss : ALIGN(16) {\n");
        fprintf(pf, "    _bss_start = .;\n");
        fprintf(pf, "    *(.bss*); *(COMMON);\n");
        fprintf(pf, "    . = ALIGN(16);\n");
        fprintf(pf, "    _bss_end = .;\n");
        fprintf(pf, "  }\n");
        fprintf(pf, "  _dtb_buffer = .;\n");
        fprintf(pf, "  . += 0x20000;\n");
        fprintf(pf, "  _stack_start = .;\n");
        fprintf(pf, "  . += 0x4000;\n");
        fprintf(pf, "  _stack_end = .;\n");
        fprintf(pf, "  _end = .;\n");
        fprintf(pf, "}\n");
        fclose(pf);
    }

    char prelink_cmd[2048];
    snprintf(prelink_cmd, sizeof(prelink_cmd),
             "aarch64-linux-gnu-ld -T %s -o %s/loader_pre.elf",
             prelink_lds, build_dir);
    for (int i = 0; i < num_loader_objects; i++) {
        strcat(prelink_cmd, " ");
        strcat(prelink_cmd, loader_objects[i]);
    }
    int ret = system(prelink_cmd);
    if (ret) {
        fprintf(stderr, "pre-link failed\n");
        return 1;
    }

    char prelink_elf[128];
    snprintf(prelink_elf, sizeof(prelink_elf), "%s/loader_pre.elf", build_dir);
    uint64_t loader_end = elf_get_end_addr(prelink_elf);
    if (!loader_end) {
        fprintf(stderr, "warning: could not read pre-link ELF, using estimate\n");
        loader_end = base + 0x10000;
    }

    uint64_t next_addr = align_page(loader_end + 0x1000);
    uint64_t payload_addrs[MAX_DOMAINS * 2 + 1];

    payload_addrs[0] = next_addr;
    next_addr = align_page(payload_addrs[0] + payloads[0].size);

    int pi = 1;
    for (int i = 0; i < num_domains; i++) {
        struct domain_cfg *d = &domains[i];
        if (d->kernel_path) {
            payload_addrs[pi] = next_addr;
            next_addr = align_page(payload_addrs[pi] + payloads[pi].size);
            pi++;
        }
        if (d->initrd_path) {
            payload_addrs[pi] = next_addr;
            next_addr = align_page(payload_addrs[pi] + payloads[pi].size);
            pi++;
        }
    }

    char payloads_s_path[128];
    snprintf(payloads_s_path, sizeof(payloads_s_path), "%s/payloads.S", build_dir);
    FILE *psf = fopen(payloads_s_path, "w");
    if (!psf) { perror("write payloads.S"); return 1; }
    write_payloads_s(psf, base, payload_addrs, NULL, num_payloads,
                     domains, num_domains, dom0_idx, xen_entry,
                     payload_addrs[0]);
    fclose(psf);

    char payloads_o_path[128];
    snprintf(payloads_o_path, sizeof(payloads_o_path), "%s/payloads.o", build_dir);

    char as_cmd[2048];
    snprintf(as_cmd, sizeof(as_cmd),
             "aarch64-linux-gnu-gcc -x assembler -c %s -o %s",
             payloads_s_path, payloads_o_path);
    ret = system(as_cmd);
    if (ret) {
        fprintf(stderr, "assembly of payloads.S failed\n");
        return 1;
    }

    char lds_path[128];
    snprintf(lds_path, sizeof(lds_path), "%s/xloader.lds", build_dir);
    FILE *lf = fopen(lds_path, "w");
    if (!lf) { perror("write xloader.lds"); return 1; }
    write_linker_script(lf, base, loader_end, payload_addrs, num_payloads,
                        domains, num_domains, dom0_idx, 0);
    fclose(lf);

    char ld_cmd[4096];
    snprintf(ld_cmd, sizeof(ld_cmd),
             "aarch64-linux-gnu-ld -T %s -o %s -Map %s/xloader.map",
             lds_path, output_path, build_dir);
    for (int i = 0; i < num_loader_objects; i++) {
        strcat(ld_cmd, " ");
        strcat(ld_cmd, loader_objects[i]);
    }
    strcat(ld_cmd, " ");
    strcat(ld_cmd, payloads_o_path);

    printf("Linking: %s\n", ld_cmd);
    ret = system(ld_cmd);
    if (ret) {
        fprintf(stderr, "final link failed\n");
        return 1;
    }

    for (int i = 0; i < num_payloads; i++)
        if (payloads[i].data) free(payloads[i].data);

    printf("bundle: %s\n", output_path);
    return 0;
}
