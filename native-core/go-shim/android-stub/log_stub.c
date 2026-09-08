#include <stdio.h>
#include <stdarg.h>
#include "android/log.h"

int __android_log_write(int prio, const char* tag, const char* text) {
    (void)prio;
    if (tag && text) {
        fprintf(stderr, "[%s] %s\n", tag, text);
    }
    return 0;
}

int __android_log_print(int prio, const char* tag, const char* fmt, ...) {
    (void)prio;
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[%s] ", tag ? tag : "xray");
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
    return 0;
}

int __android_log_vprint(int prio, const char* tag, const char* fmt, va_list ap) {
    (void)prio;
    fprintf(stderr, "[%s] ", tag ? tag : "xray");
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    return 0;
}
