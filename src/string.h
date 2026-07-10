#ifndef STRING_H
#define STRING_H

#include <stddef.h>

#define memcpy(d, s, n)    __builtin_memcpy(d, s, n)
#define memmove(d, s, n)   __builtin_memmove(d, s, n)
#define memset(s, c, n)    __builtin_memset(s, c, n)
#define memcmp(a, b, n)    __builtin_memcmp(a, b, n)
#define memchr(s, c, n)    __builtin_memchr(s, c, n)
#define strlen(s)          __builtin_strlen(s)
#define strnlen(s, n)      __builtin_strnlen(s, n)
#define strcmp(a, b)       __builtin_strcmp(a, b)
#define strncmp(a, b, n)   __builtin_strncmp(a, b, n)
#define strchr(s, c)       __builtin_strchr(s, c)

void abort(void) __attribute__((noreturn));

static inline void fmt_node_name(char* buf, int sz, const char* prefix,
                                 unsigned int v) {
    char* p = buf;
    char* end = buf + sz - 1;
    while (*prefix && p < end)
        *p++ = *prefix++;
    if (p < end)
        *p++ = '@';
    if (v == 0 && p < end) {
        *p++ = '0';
    } else {
        char tmp[16];
        int i = 0;
        while (v) {
            tmp[i++] = "0123456789abcdef"[v & 0xf];
            v >>= 4;
        }
        while (i > 0 && p < end)
            *p++ = tmp[--i];
    }
    *p = 0;
}

#endif
