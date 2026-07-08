#ifndef STRING_H
#define STRING_H

#include <stddef.h>

void *memcpy(void *dst, const void *src, size_t n);
void *memmove(void *dst, const void *src, size_t n);
void *memset(void *s, int c, size_t n);
int strcmp(const char *a, const char *b);
int strncmp(const char *a, const char *b, size_t n);
size_t strlen(const char *s);
char *strchr(const char *s, int c);
int snprintf(char *buf, size_t sz, const char *fmt, ...);

#endif
