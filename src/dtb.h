#ifndef DTB_H
#define DTB_H

#include <stdint.h>

#define FDT_MAGIC      0xD00DFEED
#define FDT_BEGIN_NODE 0x00000001
#define FDT_END_NODE   0x00000002
#define FDT_PROP       0x00000003
#define FDT_NOP        0x00000004
#define FDT_END        0x00000009

struct fdt_header {
    uint32_t magic;
    uint32_t totalsize;
    uint32_t off_dt_struct;
    uint32_t off_dt_strings;
    uint32_t off_mem_rsvmap;
    uint32_t version;
    uint32_t last_comp_version;
    uint32_t boot_cpuid_phys;
    uint32_t size_dt_strings;
    uint32_t size_dt_struct;
};

static inline uint32_t dtb_rd32(const void *p) {
    const uint8_t *d = p;
    return ((uint32_t)d[0] << 24) | ((uint32_t)d[1] << 16) |
           ((uint32_t)d[2] << 8)  | (uint32_t)d[3];
}

static inline void dtb_wr32(void *p, uint32_t v) {
    uint8_t *d = p;
    d[0] = (v >> 24) & 0xff; d[1] = (v >> 16) & 0xff;
    d[2] = (v >> 8) & 0xff;  d[3] = v & 0xff;
}

static inline int align4(int n) { return (n + 3) & ~3; }

static inline int struct_end_off(void *fdt) {
    return dtb_rd32(&((struct fdt_header*)fdt)->off_dt_struct) +
           dtb_rd32(&((struct fdt_header*)fdt)->size_dt_struct);
}

static inline int skip_name(void *fdt, int o) {
    o += 4;
    while (((char*)fdt)[o]) o++;
    return align4(o + 1);
}

int  dtb_validate(void *fdt);
int  node_end(void *fdt, int o);
int  dtb_find_chosen(void *fdt);
int  dtb_find_node_by_path(void *fdt, const char *path);
int  dtb_create_chosen(void *fdt);
void dtb_insert(void *fdt, int at, int sz);
int  dtb_add_module(void *fdt, int chosen_off,
                    uint64_t addr, uint64_t size,
                    const char *mod_name, const char *bootargs,
                    const char *kind_compat);
int  dtb_add_domain(void *fdt, int chosen_off, void *src_fdt,
                    uint64_t kaddr, uint64_t ksize,
                    uint64_t iaddr, uint64_t isize,
                    const char *cmdline, uint64_t mem_size_kb,
                    int dom_idx,
                    const char *const *paths, int np,
                    const char *const *paths_str, int nps);
int  dtb_copy_node_to_buf(void *dst_fdt, void *src_fdt, const char *path,
                          char *buf, int bufsz);
int  dtb_add_string(void *fdt, const char *s);
void dtb_finalize(void *fdt);

#endif
