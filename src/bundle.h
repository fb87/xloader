#ifndef XEN_BUNDLE_H
#define XEN_BUNDLE_H

#include <stdint.h>

#define XEN_BUNDLE_MAGIC 0x58454E42554E444CULL
#define XEN_BUNDLE_VERSION 2
#define XEN_BUNDLE_MAX_DOMAINS 16
#define XEN_BUNDLE_MAX_PASSTHROUGH 32
#define XEN_BUNDLE_CMDLINE_LEN 256
#define XEN_BUNDLE_MAX_PATHS 64

struct xen_domain_desc {
    uint64_t kernel_addr;
    uint64_t kernel_size;
    uint64_t initrd_addr;
    uint64_t initrd_size;
    uint64_t dtb_addr;
    uint64_t dtb_size;
    uint64_t memory_kb;
    char cmdline[XEN_BUNDLE_CMDLINE_LEN];
    uint32_t num_passthrough;
    uint32_t passthrough_off;
    uint32_t num_passthrough_strings;
    uint32_t passthrough_strings_off;
} __attribute__((packed));

struct xen_bundle_desc {
    uint64_t magic;
    uint64_t version;
    uint64_t bundle_addr;
    uint64_t xen_addr;
    uint64_t xen_size;
    uint64_t xen_entry;
    uint64_t num_domains;
    uint64_t dom0_idx;
    uint64_t dtb_ptr;
    uint64_t dtb_size;
    uint64_t ram_size;
    struct xen_domain_desc domains[XEN_BUNDLE_MAX_DOMAINS];
};

#endif
