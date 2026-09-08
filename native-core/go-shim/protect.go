package main

/*
#include <stdint.h>
typedef int (*protect_func_t)(int fd);
static inline int call_protect(protect_func_t f, int fd) {
    if (f == NULL) {
        return 1; // 没注册回调时，默认不拦截，避免直接拒绝所有连接
    }
    return f(fd);
}
*/
import "C"

import (
	"sync"
)

var (
	protectMu   sync.Mutex
	protectFunc C.protect_func_t
)

//export XraySetProtectFunc
func XraySetProtectFunc(fn C.protect_func_t) {
	protectMu.Lock()
	protectFunc = fn
	protectMu.Unlock()
}

// callProtect 供后续自定义 dialer 钩子使用；当前出站防环
// 由 ArkTS 侧 VpnConnection.protectProcessNet() 进程级完成。
func callProtect(fd int) int {
	protectMu.Lock()
	fn := protectFunc
	protectMu.Unlock()
	return int(C.call_protect(fn, C.int(fd)))
}
