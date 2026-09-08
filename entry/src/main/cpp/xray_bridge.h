#ifndef XRAY_BRIDGE_H
#define XRAY_BRIDGE_H

#include <string>

// 下面这组 extern "C" 声明对应 native-core/go-shim/main.go 中用
// `//export` 标注、并以 `go build -buildmode=c-shared` 编译出的符号。
// 实际签名请以编译产物自动生成的 libxraycore.h 为准，这里手写是为了
// 在还没有完成交叉编译产物之前，C++侧代码也能独立编译/补全逻辑。
extern "C" {
    // 成功返回长度为0的字符串，否则返回错误描述。
    // 返回值由 Go runtime 通过 C.CString 分配，调用方须负责 free()。
    char* XrayStart(const char* configJson);
    void XrayStop();
    int XrayIsRunning();
    // 同样需要 free() 返回值。
    char* XrayQueryStats(const char* tag);
    // 在 Go runtime 内 os.Setenv 写入 TUN fd（C setenv 对本平台不可见）。
    void XraySetTunFd(int fd);
    // 设置 geoip.dat / geosite.dat 目录（xray.location.asset）。
    void XraySetAssetPath(const char* path);
    // 注册同步 protect 回调。Go 侧出站拨号时会同步调用此回调，
    // 返回 0 表示拦截（走 VPN），返回 1 表示不拦截（直连）。
    // 注意：鸿蒙 vpnConnection.protect(fd) 是异步的，无法在同步回调里
    // 直接 await。第一阶段用 excludeRoutes 替代，回调恒返回 1。
    void XraySetProtectFunc(int (*fn)(int fd));
}

// 给native层（本文件）使用的封装，内部处理：
//   1. 把 tunFd 写入环境变量 xray.tun.fd（主）与 XRAY_TUN_FD（AltName 双保险），
//      供 Xray 的 tun inbound 读取（platform.EnvFlag，OhosTun.NewTun 消费）；
//      Xray 配置根级 env 也会写同一份。
//   2. 可选设置 xray.location.asset（geoip.dat / geosite.dat）。
//   3. 调用Go导出的XrayStart，并安全释放其返回的C字符串。
std::string XrayBridgeStart(const std::string& configJson, int tunFd, const std::string& assetPath = "");
void XrayBridgeStop();
bool XrayBridgeIsRunning();
std::string XrayBridgeQueryStats(const std::string& tag);

#endif // XRAY_BRIDGE_H
