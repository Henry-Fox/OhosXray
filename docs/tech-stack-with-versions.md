# OhosXray 技术栈与版本

> 本文档为项目固化技术栈。未获明确指令不得随意调整大版本。

## 应用层（HarmonyOS / OpenHarmony）

| 组件 | 版本 | 说明 |
|------|------|------|
| DevEco / modelVersion | 26.0.0 | `oh-package.json5` / `hvigor` |
| compileSdkVersion / targetSdkVersion | 26.0.0 | `build-profile.json5` |
| compatibleSdkVersion | 12 | API 12+ |
| runtimeOS | OpenHarmony | |
| 语言 | ArkTS | entry 模块 `.ets` |
| 包名 | com.example.ohosxray | |

## Native 桥接

| 组件 | 版本 / 约定 | 说明 |
|------|-------------|------|
| CMake | 3.5+ | `entry/src/main/cpp/CMakeLists.txt` |
| NAPI 模块 | libxraybridge.so | `napi_init.cpp` + `xray_bridge.cpp` |
| Go shim | ohosxray/goshim | `native-core/go-shim` |
| Xray-core | git tag **v26.6.1**（commit `94ffd500…`） | Go module 伪版本 `v0.0.0-20260601021109-94ffd50060f1` |
| Go | 1.26.x（本机 go1.26.4） | 交叉编译 `GOOS=android GOARCH=arm64` |
| OHOS NDK | SDK 26.0.0 native llvm | `clang --target=aarch64-linux-ohos` |
| 产物 | libxraycore.so (arm64-v8a) | 需同时放到 `entry/src/main/cpp/libs`（链接）与 `entry/libs`（打包） |

## 关键约定：TUN fd 传递

1. ArkTS `VpnConnection.create()` 得到 `tunFd`
2. C++ 调用 **`XraySetTunFd(tunFd)`**（Go 内 `os.Setenv("xray.tun.fd" / "XRAY_TUN_FD")`）
3. 再 `XrayStart(configJson)`；AndroidTun 通过 `platform.EnvFlag` 读取
4. **不要只依赖 C `setenv`**：在鸿蒙上对 Go `os.LookupEnv` 不可见，会导致读到 fd=0
5. gVisor `fdbased.isSocketFD` 已本地 patch（`native-core/third_party/gvisor`）：鸿蒙 TUN fd 的 `Fstat` 会 permission denied，改为失败时按非 socket 走 Readv

## 重建 Go 核心

```powershell
cd native-core\go-shim
powershell -ExecutionPolicy Bypass -File .\build_ohos_arm64.ps1
```

## 文档与参考

- Xray-core: https://github.com/XTLS/Xray-core
- Xray TUN 说明: https://xtls.github.io/config/inbounds/tun.html
- HarmonyOS VPN Extension / NetworkKit（DevEco SDK 文档）
- OpenHarmony SDK 下载: https://developer.huawei.com/consumer/cn/download
