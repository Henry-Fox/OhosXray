# OhosXray 技术栈与版本

> 本文档为项目固化技术栈。未获明确指令不得随意调整大版本。

## 应用层（HarmonyOS / OpenHarmony）

| 组件 | 版本 | 说明 |
|------|------|------|
| DevEco / modelVersion | 26.0.0 | `oh-package.json5` / `hvigor` |
| compileSdkVersion / targetSdkVersion | 26.0.0 | `build-profile.json5` |
| compatibleSdkVersion | 5.0.0(12) | HarmonyOS 字符串格式；最低兼容 API 12 |
| runtimeOS | **HarmonyOS** | 使用 HMS Scan Kit 需要 HarmonyOS（非纯 OpenHarmony） |
| 语言 | ArkTS | entry 模块 `.ets` |
| 包名 | com.example.ohosxray | |
| 扫码 | `@kit.ScanKit`（`scanBarcode.startScanForResult`） | 系统默认扫码 UI + 相册；入口仅在「添加节点」；文档 https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/scan-scanbarcode |

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

## 智能分流（默认）

- **按目标地址判断**，不是整片「国内模式/国外模式」切换
- 实现：
  1. 智能分流时把 **Loyalsoldier/geoip 全量国内 IPv4 CIDR**（`cn-ipv4.txt`，约 6k 段）配成 VPN `isExcludedRoute` → 系统层直连  
     - 支持网段（`address` + `prefixLength`）  
     - API 23+ 路由上限 **10000**（本机 API 24 可用全量；旧机 1024 需精简）  
     - 启动后台每 24h 从 jsDelivr/GitHub 自动更新 `cn.txt`
  2. 进入 TUN 的其余流量默认走 `proxy`；Xray 侧仍用完整 `geosite.dat`/`geoip.dat` 做域名/IP 兜底
  3. 另排除节点 IP、常用 DNS、局域网段
- geo 域名/IP 库：`geosite.dat` / `geoip.dat`（Loyalsoldier 全量），后台自动更新
- UI：智能分流 / 全局代理

## 切网自动重连

- 根因：`sendThrough` 绑死启动时物理 IPv4；切网后出现 `bind: cannot assign requested address`
- 策略（v2）：
  1. 每 2.5s 轮询物理 IP（VPN 下 NetConnection 可能不回调）
  2. 同时订阅默认 `createNetConnection()` 事件
  3. IP 变化时 **软重启 Xray**（保留 TUN fd；AndroidTun.Close 不关 fd）并换新 `sendThrough`
  4. 软重启失败再全量 destroy/create VPN
- **必须用含本逻辑的新 HAP 验证**；旧包日志不会出现 `net-reconnect=v2` / `netPoll` / `softRestart`

## 分发定位（写死）

- 仅调试签名 + 开发者模式；半自动安装见 `tools/install-ohosxray.*`
- 熟人文档：`docs/install-for-friends.md`；Agent SOP：`docs/agent-sop-install.md`
- 不提供绕过安装限制或应用市场上架规避指导

## 重建 Go 核心

```powershell
cd native-core\go-shim
powershell -ExecutionPolicy Bypass -File .\build_ohos_arm64.ps1
```

## 文档与参考

- Xray-core: https://github.com/XTLS/Xray-core
- Xray TUN 说明: https://xtls.github.io/config/inbounds/tun.html
- geo 规则数据: https://github.com/Loyalsoldier/v2ray-rules-dat
- HarmonyOS VPN Extension / NetworkKit（DevEco SDK 文档）
- OpenHarmony SDK 下载: https://developer.huawei.com/consumer/cn/download
- 网络连接管理（NetConnection / NOT_VPN）: HarmonyOS NetworkKit `connection` 文档
