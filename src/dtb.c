#include "dtb.h"
#include "string.h"

static inline int struct_off(void *fdt) {
    return dtb_rd32(&((struct fdt_header*)fdt)->off_dt_struct);
}
static inline int strings_off(void *fdt) {
    return dtb_rd32(&((struct fdt_header*)fdt)->off_dt_strings);
}

int node_end(void *fdt, int o) {
    o = skip_name(fdt, o);
    int depth = 0;
    for (;;) {
        uint32_t t = dtb_rd32(fdt + o);
        switch (t) {
        case FDT_BEGIN_NODE:
            depth++;
            o = skip_name(fdt, o);
            break;
        case FDT_END_NODE:
            if (!depth) return o;
            depth--;
            o += 4;
            break;
        case FDT_PROP: {
            int l = dtb_rd32(fdt + o + 4);
            o += 12 + align4(l);
            break;
        }
        case FDT_NOP: o += 4; break;
        case FDT_END: return -1;
        default: return -1;
        }
    }
}

static int node_name_len(void *fdt, int o) {
    const char *s = fdt + o + 4;
    int l = 0;
    while (s[l]) l++;
    return l;
}

void dtb_insert(void *fdt, int at, int sz) {
    struct fdt_header *h = fdt;
    int ts = dtb_rd32(&h->totalsize);
    int so = dtb_rd32(&h->off_dt_strings);
    int ss = dtb_rd32(&h->size_dt_struct);
    memmove(fdt + at + sz, fdt + at, ts - at);
    if (at < so)
        dtb_wr32(&h->size_dt_struct, ss + sz);
    else
        dtb_wr32(&h->size_dt_strings, dtb_rd32(&h->size_dt_strings) + sz);
    if (at <= so)
        dtb_wr32(&h->off_dt_strings, so + sz);
    dtb_wr32(&h->totalsize, ts + sz);
}

int dtb_validate(void *fdt) {
    return dtb_rd32(fdt) == FDT_MAGIC ? 0 : -1;
}

int dtb_find_chosen(void *fdt) {
    int o = struct_off(fdt);
    int e = struct_end_off(fdt);
    /* Enter root node (empty name) */
    uint32_t t = dtb_rd32(fdt + o);
    if (t != FDT_BEGIN_NODE) return -1;
    int ne = node_end(fdt, o);
    if (ne < 0) return -1;
    o = skip_name(fdt, o);
    e = ne;

    while (o < e) {
        t = dtb_rd32(fdt + o);
        if (t != FDT_BEGIN_NODE) { o += 4; continue; }
        const char *nm = fdt + o + 4;
        if (!strcmp(nm, "chosen")) return o;
        ne = node_end(fdt, o);
        if (ne < 0) return -1;
        o = ne + 4;
    }
    return -1;
}

int dtb_find_node_by_path(void *fdt, const char *path) {
    if (!path || !*path) return -1;
    if (*path == '/') path++;
    if (!*path) return struct_off(fdt);

    char comp[256];
    int o = struct_off(fdt);
    int e = struct_end_off(fdt);

    while (o < e) {
        uint32_t t = dtb_rd32(fdt + o);
        if (t != FDT_BEGIN_NODE) { o += 4; continue; }
        int nl = node_name_len(fdt, o);
        const char *nm = fdt + o + 4;

        /* Root node has empty name — skip name, descend inside */
        if (nl == 0) {
            int ne = node_end(fdt, o);
            if (ne < 0) return -1;
            o = skip_name(fdt, o);
            e = ne;
            continue;
        }

        if (nl > 255) nl = 255;
        memcpy(comp, nm, nl);
        comp[nl] = 0;

        const char *slash = strchr(path, '/');
        int pcl = slash ? (int)(slash - path) : (int)strlen(path);

        if ((int)strlen(comp) == pcl && !strncmp(comp, path, pcl)) {
            if (!slash) return o;
            path = slash + 1;
            int ne = node_end(fdt, o);
            if (ne < 0) return -1;
            o = skip_name(fdt, o);
            e = ne;
            continue;
        }
        int ne = node_end(fdt, o);
        if (ne < 0) return -1;
        o = ne + 4;
    }
    return -1;
}

int dtb_create_chosen(void *fdt) {
    int o = struct_end_off(fdt) - 4;
    if (dtb_rd32(fdt + o) != FDT_END)
        return -1;

    char buf[128];
    int bo = 0;
    dtb_wr32(buf + bo, FDT_BEGIN_NODE); bo += 4;
    memcpy(buf + bo, "chosen", 7); bo += 7;
    while (bo & 3) { buf[bo++] = 0; }
    dtb_wr32(buf + bo, FDT_END_NODE); bo += 4;

    dtb_insert(fdt, o, bo);
    memcpy(fdt + o, buf, bo);
    return o;
}

int dtb_add_string(void *fdt, const char *s) {
    struct fdt_header *h = fdt;
    int so = dtb_rd32(&h->off_dt_strings);
    int ss = dtb_rd32(&h->size_dt_strings);
    int at = so + ss;
    int len = strlen(s) + 1;
    int alen = align4(len);
    dtb_wr32(&h->size_dt_strings, ss + alen);
    dtb_wr32(&h->totalsize, dtb_rd32(&h->totalsize) + alen);
    memcpy(fdt + at, s, len);
    if (alen > len) memset(fdt + at + len, 0, alen - len);
    return ss;
}

static int w_begin_node(char *buf, const char *name) {
    int o = 0;
    dtb_wr32(buf + o, FDT_BEGIN_NODE); o += 4;
    int l = strlen(name) + 1;
    memcpy(buf + o, name, l); o += l;
    while (o & 3) { buf[o++] = 0; }
    return o;
}

static int w_end_node(char *buf) {
    dtb_wr32(buf, FDT_END_NODE);
    return 4;
}

static int w_prop(char *buf, int name_off, const void *val, int len) {
    int o = 0;
    dtb_wr32(buf + o, FDT_PROP); o += 4;
    dtb_wr32(buf + o, len); o += 4;
    dtb_wr32(buf + o, name_off); o += 4;
    memcpy(buf + o, val, len); o += len;
    while (o & 3) { ((char*)buf)[o++] = 0; }
    return o;
}

int dtb_add_module(void *fdt, int chosen_off,
                   uint64_t addr, uint64_t size,
                   const char *mod_name, const char *bootargs,
                   const char *kind_compat)
{
    int ne = node_end(fdt, chosen_off);
    if (ne < 0) return -1;

    char buf[1024];
    int o = 0;

    o += w_begin_node(buf + o, mod_name);

    int no = dtb_add_string(fdt, "compatible");
    if (kind_compat) {
        /* domU-style: "multiboot,module\0<kind>\0" */
        static const char mb_module[] = "multiboot,module";
        int klen = strlen(kind_compat) + 1;
        int mblen = sizeof(mb_module);
        char compat_val[64];
        memcpy(compat_val, mb_module, mblen);
        memcpy(compat_val + mblen, kind_compat, klen);
        o += w_prop(buf + o, no, compat_val, mblen + klen);
    } else {
        o += w_prop(buf + o, no, "xen,multiboot-module", 21);
    }

    uint32_t cells[4];
    cells[0] = __builtin_bswap32((uint32_t)(addr >> 32));
    cells[1] = __builtin_bswap32((uint32_t)addr);
    cells[2] = __builtin_bswap32((uint32_t)(size >> 32));
    cells[3] = __builtin_bswap32((uint32_t)size);
    no = dtb_add_string(fdt, "reg");
    o += w_prop(buf + o, no, cells, 16);

    if (bootargs && *bootargs) {
        no = dtb_add_string(fdt, "bootargs");
        o += w_prop(buf + o, no, bootargs, strlen(bootargs) + 1);
    }

    o += w_end_node(buf + o);

    dtb_insert(fdt, ne, o);
    memcpy(fdt + ne, buf, o);
    return 0;
}

static int build_domain_node(char *buf, void *fdt, void *src_fdt,
                             uint64_t kaddr, uint64_t ksize,
                             uint64_t iaddr, uint64_t isize,
                             const char *cmdline,
                             uint64_t mem_size_kb,
                             const char *name,
                             const char *const *paths, int np,
                             const char *const *paths_str, int nps)
{
    (void)paths_str; (void)nps;
    int o = 0;
    o += w_begin_node(buf + o, name);

    int no = dtb_add_string(fdt, "compatible");
    o += w_prop(buf + o, no, "xen,domain", 11);

    no = dtb_add_string(fdt, "#address-cells");
    uint32_t ac = __builtin_bswap32(2U);
    o += w_prop(buf + o, no, &ac, 4);

    no = dtb_add_string(fdt, "#size-cells");
    uint32_t sc = __builtin_bswap32(1U);
    o += w_prop(buf + o, no, &sc, 4);

    no = dtb_add_string(fdt, "cpus");
    uint32_t cpus = __builtin_bswap32(1U);
    o += w_prop(buf + o, no, &cpus, 4);

    uint32_t mem[2];
    mem[0] = __builtin_bswap32((uint32_t)(mem_size_kb >> 32));
    mem[1] = __builtin_bswap32((uint32_t)mem_size_kb);
    no = dtb_add_string(fdt, "memory");
    o += w_prop(buf + o, no, mem, 8);

    static const char empty;
    no = dtb_add_string(fdt, "vpl011");
    o += w_prop(buf + o, no, &empty, 0);

    no = dtb_add_string(fdt, "xen,enhanced");
    o += w_prop(buf + o, no, "no-xenstore", 12);

    if (cmdline && *cmdline) {
        no = dtb_add_string(fdt, "bootargs");
        o += w_prop(buf + o, no, cmdline, strlen(cmdline) + 1);
    }

    char mname[32];
    int mi = 0;

    if (kaddr && ksize) {
        int slen = snprintf(mname, sizeof(mname), "module@%x", mi++);
        (void)slen;
        char mbuf[512];
        int mo = 0;
        mo += w_begin_node(mbuf + mo, mname);
        int nno = dtb_add_string(fdt, "compatible");
        static const char compat_kernel[] = "multiboot,module\0multiboot,kernel";
        mo += w_prop(mbuf + mo, nno, compat_kernel, sizeof(compat_kernel));
        uint32_t ck[3];
        ck[0] = __builtin_bswap32((uint32_t)(kaddr >> 32));
        ck[1] = __builtin_bswap32((uint32_t)kaddr);
        ck[2] = __builtin_bswap32((uint32_t)ksize);
        nno = dtb_add_string(fdt, "reg");
        mo += w_prop(mbuf + mo, nno, ck, 12);
        mo += w_end_node(mbuf + mo);
        memcpy(buf + o, mbuf, mo); o += mo;
    }

    if (iaddr && isize) {
        int slen = snprintf(mname, sizeof(mname), "module@%x", mi++);
        (void)slen;
        char mbuf[512];
        int mo = 0;
        mo += w_begin_node(mbuf + mo, mname);
        int nno = dtb_add_string(fdt, "compatible");
        static const char compat_ramdisk[] = "multiboot,module\0multiboot,ramdisk";
        mo += w_prop(mbuf + mo, nno, compat_ramdisk, sizeof(compat_ramdisk));
        uint32_t ci[3];
        ci[0] = __builtin_bswap32((uint32_t)(iaddr >> 32));
        ci[1] = __builtin_bswap32((uint32_t)iaddr);
        ci[2] = __builtin_bswap32((uint32_t)isize);
        nno = dtb_add_string(fdt, "reg");
        mo += w_prop(mbuf + mo, nno, ci, 12);
        mo += w_end_node(mbuf + mo);
        memcpy(buf + o, mbuf, mo); o += mo;
    }

    for (int pi = 0; pi < np; pi++) {
        int sub = dtb_copy_node_to_buf(fdt, src_fdt, paths[pi],
                                        buf + o, 4096);
        if (sub > 0) o += sub;
    }

    o += w_end_node(buf + o);
    return o;
}

int dtb_copy_node_to_buf(void *dst_fdt, void *src_fdt, const char *path,
                         char *buf, int bufsz)
{
    int src_off;
    if (path && *path && *path != '/') {
        src_off = dtb_find_node_by_path(src_fdt, path);
    } else if (path && *path == '/') {
        src_off = dtb_find_node_by_path(src_fdt, path);
    } else {
        return -1;
    }
    if (src_off < 0) return -1;

    int no = skip_name(src_fdt, src_off);
    int ne = node_end(src_fdt, src_off);
    if (ne < 0) return -1;

    int sso = strings_off(src_fdt);
    int bo = 0;

    const char *nm = src_fdt + src_off + 4;
    bo += w_begin_node(buf + bo, nm);

    while (no < ne) {
        uint32_t t = dtb_rd32(src_fdt + no);
        if (t == FDT_PROP) {
            int l = dtb_rd32(src_fdt + no + 4);
            int name_off_src = dtb_rd32(src_fdt + no + 8);
            const char *pn = (const char*)src_fdt + sso + name_off_src;
            int name_off_dst = dtb_add_string(dst_fdt, pn);
            int al = align4(l);
            if (bo + 12 + al > bufsz) return -1;
            dtb_wr32(buf + bo, FDT_PROP); bo += 4;
            dtb_wr32(buf + bo, l); bo += 4;
            dtb_wr32(buf + bo, name_off_dst); bo += 4;
            memcpy(buf + bo, src_fdt + no + 12, l); bo += l;
            while (bo & 3) { buf[bo++] = 0; }
            no += 12 + al;
        } else if (t == FDT_BEGIN_NODE) {
            int sub = dtb_copy_node_to_buf(dst_fdt, src_fdt, "", buf + bo, bufsz - bo);
            if (sub < 0) return -1;
            int sne = node_end(src_fdt, no);
            if (sne < 0) return -1;
            no = sne + 4;
        } else if (t == FDT_END_NODE) {
            break;
        } else {
            no += 4;
        }
    }

    bo += w_end_node(buf + bo);
    return bo;
}

int dtb_add_domain(void *fdt, int chosen_off, void *src_fdt,
                   uint64_t kaddr, uint64_t ksize,
                   uint64_t iaddr, uint64_t isize,
                   const char *cmdline, uint64_t mem_size_kb,
                   int dom_idx,
                   const char *const *paths, int np,
                   const char *const *paths_str, int nps)
{
    int ne = node_end(fdt, chosen_off);
    if (ne < 0) return -1;

    char name[32];
    snprintf(name, sizeof(name), "domain@%x", dom_idx);

    char buf[8192];
    int o = build_domain_node(buf, fdt, src_fdt,
                              kaddr, ksize, iaddr, isize,
                              cmdline, mem_size_kb, name,
                              paths, np, paths_str, nps);
    if (o <= 0 || o > (int)sizeof(buf)) return -1;

    dtb_insert(fdt, ne, o);
    memcpy(fdt + ne, buf, o);
    return 0;
}

void dtb_finalize(void *fdt) {
    struct fdt_header *h = fdt;
    int se = struct_end_off(fdt);
    int fdt_end_off = se - 4;
    if (dtb_rd32(fdt + fdt_end_off) != FDT_END) {
        dtb_wr32(fdt + se, FDT_END);
        dtb_wr32(&h->size_dt_struct, dtb_rd32(&h->size_dt_struct) + 4);
        dtb_wr32(&h->totalsize, dtb_rd32(&h->totalsize) + 4);
    }
}
