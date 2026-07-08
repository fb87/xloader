#include "string.h"
#include <stdarg.h>

void *memcpy(void *dst, const void *src, size_t n) {
    unsigned char *d = dst;
    const unsigned char *s = src;
    for (size_t i = 0; i < n; i++) d[i] = s[i];
    return dst;
}

void *memmove(void *dst, const void *src, size_t n) {
    unsigned char *d = dst;
    const unsigned char *s = src;
    if (d < s) {
        for (size_t i = 0; i < n; i++) d[i] = s[i];
    } else if (d > s) {
        for (size_t i = n; i > 0; i--) d[i-1] = s[i-1];
    }
    return dst;
}

void *memset(void *s, int c, size_t n) {
    unsigned char *p = s;
    for (size_t i = 0; i < n; i++) p[i] = (unsigned char)c;
    return s;
}

int strcmp(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}

int strncmp(const char *a, const char *b, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (a[i] != b[i]) return (unsigned char)a[i] - (unsigned char)b[i];
        if (!a[i]) return 0;
    }
    return 0;
}

size_t strlen(const char *s) {
    size_t n = 0;
    while (*s++) n++;
    return n;
}

char *strchr(const char *s, int c) {
    while (*s) {
        if (*s == (char)c) return (char*)s;
        s++;
    }
    return (char*)(c ? s + 1 : s);
}

int snprintf(char *buf, size_t sz, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    size_t pos = 0;

    for (const char *p = fmt; *p && pos < sz; p++) {
        if (*p != '%') {
            buf[pos++] = *p;
            continue;
        }
        p++;
        switch (*p) {
        case 's': {
            const char *s = va_arg(ap, const char*);
            while (*s && pos < sz) buf[pos++] = *s++;
            break;
        }
        case 'd':
        case 'x': {
            int hex = (*p == 'x');
            unsigned long v = va_arg(ap, unsigned int);
            if (!hex) v = va_arg(ap, int);
            char tmp[20];
            int ti = 0;
            if (v == 0) { tmp[ti++] = '0'; }
            else {
                while (v > 0) {
                    int d = v % (hex ? 16 : 10);
                    tmp[ti++] = d < 10 ? '0' + d : 'a' + d - 10;
                    v /= (hex ? 16 : 10);
                }
            }
            for (int j = ti - 1; j >= 0 && pos < sz; j--)
                buf[pos++] = tmp[j];
            break;
        }
        case 'l': {
            p++;
            if (*p == 'x' || *p == 'd') {
                int hex = (*p == 'x');
                unsigned long v = va_arg(ap, unsigned long);
                char tmp[24];
                int ti = 0;
                if (v == 0) { tmp[ti++] = '0'; }
                else {
                    while (v > 0) {
                        int d = v % (hex ? 16 : 10);
                        tmp[ti++] = d < 10 ? '0' + d : 'a' + d - 10;
                        v /= (hex ? 16 : 10);
                    }
                }
                for (int j = ti - 1; j >= 0 && pos < sz; j--)
                    buf[pos++] = tmp[j];
            }
            break;
        }
        default:
            if (pos < sz) buf[pos++] = *p;
            break;
        }
    }
    va_end(ap);
    if (pos < sz) buf[pos] = 0;
    else if (sz > 0) buf[sz-1] = 0;
    return pos;
}
