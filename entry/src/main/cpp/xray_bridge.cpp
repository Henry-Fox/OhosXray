#include "xray_bridge.h"
#include <cstdlib>
#include <cstdio>
#include <cstring>

namespace {

// Go runtime通过C.CString()分配的字符串，调用方负责释放。
std::string TakeOwnership(char* cstr) {
    if (cstr == nullptr) {
        return std::string();
    }
    std::string result(cstr);
    free(cstr); // 对应 Go 侧 C.CString 底层的 malloc
    return result;
}

// 默认 protect 回调：恒返回 1（不拦截，直连）。
// 出站防回环由 ArkTS 侧 VpnConnection.protectProcessNet() 在进程级完成
// （VPN 进程后续创建的所有 socket，含本 Go 核心，全部绕过 TUN 走物理网卡），
// 因此 Go 侧逐 socket 回调无需再做拦截。
int DefaultProtectCallback(int fd) {
    return 1;
}

}  // namespace

std::string XrayBridgeStart(const std::string& configJson, int tunFd, const std::string& assetPath) {
    // 关键：必须先走 Go 导出的 XraySetTunFd（内部 os.Setenv）。
    // 鸿蒙上 C setenv 对 Go runtime 的 os.LookupEnv 不可见，会导致
    // AndroidTun 读到 fd=0（stdin），TUN RX 恒为 0。
    XraySetTunFd(tunFd);

    if (!assetPath.empty()) {
        XraySetAssetPath(assetPath.c_str());
    }

    // C setenv 保留作双保险（对部分工具链/诊断场景仍有用）。
    char fdBuf[16] = {0};
    snprintf(fdBuf, sizeof(fdBuf), "%d", tunFd);
    setenv("xray.tun.fd", fdBuf, 1);
    setenv("XRAY_TUN_FD", fdBuf, 1);

    // 启动前注册默认 protect 回调。
    // 出站防回环以 ArkTS 侧 VpnConnection.protectProcessNet() 为主（进程级绕过），
    // 回调恒返回 1（不拦截）与之保持一致。
    XraySetProtectFunc(DefaultProtectCallback);

    char* errCStr = XrayStart(configJson.c_str());
    return TakeOwnership(errCStr);
}

void XrayBridgeStop() {
    XrayStop();
    unsetenv("xray.tun.fd");
    unsetenv("XRAY_TUN_FD");
}

bool XrayBridgeIsRunning() {
    return XrayIsRunning() != 0;
}

std::string XrayBridgeQueryStats(const std::string& tag) {
    char* statsCStr = XrayQueryStats(tag.c_str());
    std::string result = TakeOwnership(statsCStr);
    if (result.empty()) {
        return "{\"uplink\":0,\"downlink\":0}";
    }
    return result;
}
