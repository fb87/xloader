/* Minimal freestanding string implementations.
 * GCC __builtin_* emits calls to these symbols for large copies.
 * The #define macros in string.h only apply to files that include it
 * (like main.c); libfdt's own .c files include <string.h> directly and
 * expect real symbols.  These stubs are the minimum required glue. */

#include "string.h"

#undef memcpy
void* memcpy(void* d, const void* s, size_t n);
void* memcpy(void* d, const void* s, size_t n) {
    unsigned char* dp = d;
    const unsigned char* sp = s;
    while (n--) *dp++ = *sp++;
    return d;
}

#undef memmove
void* memmove(void* d, const void* s, size_t n);
void* memmove(void* d, const void* s, size_t n) {
    unsigned char* dp = d;
    const unsigned char* sp = s;
    if (dp < sp) {
        while (n--) *dp++ = *sp++;
    } else if (dp > sp) {
        dp += n; sp += n;
        while (n--) *--dp = *--sp;
    }
    return d;
}

#undef memset
void* memset(void* s, int c, size_t n);
void* memset(void* s, int c, size_t n) {
    unsigned char* p = s;
    while (n--) *p++ = (unsigned char)c;
    return s;
}

#undef memcmp
int memcmp(const void* a, const void* b, size_t n);
int memcmp(const void* a, const void* b, size_t n) {
    const unsigned char* pa = a, *pb = b;
    for (size_t i = 0; i < n; i++)
        if (pa[i] != pb[i]) return pa[i] - pb[i];
    return 0;
}

#undef memchr
void* memchr(const void* s, int c, size_t n);
void* memchr(const void* s, int c, size_t n) {
    const unsigned char* p = s;
    for (size_t i = 0; i < n; i++)
        if (p[i] == (unsigned char)c) return (void*)(p + i);
    return 0;
}

#undef strlen
size_t strlen(const char* s);
size_t strlen(const char* s) {
    size_t n = 0;
    while (*s++) n++;
    return n;
}

#undef strnlen
size_t strnlen(const char* s, size_t n);
size_t strnlen(const char* s, size_t n) {
    size_t len = 0;
    while (len < n && *s++) len++;
    return len;
}

#undef strcmp
int strcmp(const char* a, const char* b);
int strcmp(const char* a, const char* b) {
    while (*a && *a == *b) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}

#undef strncmp
int strncmp(const char* a, const char* b, size_t n);
int strncmp(const char* a, const char* b, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (a[i] != b[i]) return (unsigned char)a[i] - (unsigned char)b[i];
        if (!a[i]) return 0;
    }
    return 0;
}

#undef strchr
char* strchr(const char* s, int c);
char* strchr(const char* s, int c) {
    while (*s) {
        if (*s == (char)c) return (char*)s;
        s++;
    }
    return (char*)(c ? s + 1 : s);
}

#undef strrchr
char* strrchr(const char* s, int c);
char* strrchr(const char* s, int c) {
    const char* last = 0;
    while (*s) { if (*s == (char)c) last = s; s++; }
    if (!c) last = s;
    return (char*)last;
}

void abort(void) {
    while (1) asm volatile("wfi");
}
