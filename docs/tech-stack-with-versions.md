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

## 日志滚动

- app.log：超过 512KB 截断重写
- xray-error.log：超过 1MB 截断；启动时清理旧 xray-access.log
- TUN 模式 Xray loglevel=warning，不再写 access 流量日志（避免冲掉诊断）

## 切网自动重连

- 根因（两层）：
  1. **数据面**：鸿蒙无 Android `setUnderlyingNetworks`；切 WiFi 后旧 `VpnConnection`/TUN 失效，仅换 Xray `sendThrough`（软重启）不够
  2. **控制面**：扩展进程可能被系统杀掉（`onProcessDied`）；UI 曾钉死「已连接」
- 策略（**v3.3-hbfile+debounce-cap**，日志 `net-reconnect=v3.3-hbfile+debounce-cap` / `full-` / `healVpnIfStale`）：
  1. 每 2.5s 轮询物理 IP + iface；订阅 `netAvailable` / `netLost` / `netConnectionPropertiesChange`
  2. 链路变化防抖 **4.5s**；**已有定时器不重置**（v3.1 回归：轮询 2.5s 反复 reset 导致永远不重建）；事件 reset **封顶 8s**（v3.3：蜂窝高频 propertiesChange 可无限续命定时器，饿死重建）
  3. 全量重建成功后 **12s 冷却**；IP/iface 变化或不健康 → destroy + create
  4. 心跳走**共享沙箱文件** `filesDir/vpn_hb.txt`（内容 `${ms}|${physIp}`）：Preferences 是每进程独立缓存，主进程看不到 :vpn 进程 flush 的写入，v3.2 因此把健康扩展误判 stale（age 永增）反复 stop+start，移动网络下事件吵、症状最重
  5. 扩展每 **30s** 写心跳；主进程 >**150s** 判死，且 stop+start 前**二次重读文件确认**（heal 同步占坑 + 15s 冷却防连打）
  6. Xray error 泵只读增量；UI 以心跳新鲜度显示连接态
- 实机验证（Mate 80 Pro，2026-09-16）：WiFi↔蜂窝双向切换 ~10s 内 `full recreate ... OK`，全程无 `restarting extension`
- **必须用含本逻辑的新 HAP 验证**；旧包关键字不同

## 产品定位与验证机

- **鸿蒙系统级 VPN**（`VpnExtensionAbility` + TUN + Xray），非普通本机代理面板
- **主测机：HUAWEI Mate 80 Pro**（安装脚本、全局 VPN、智能分流已验）
- 仅调试签名 + 开发者模式；半自动安装见 `tools/install-ohosxray.*`
- 熟人文档：`docs/install-for-friends.md`；Agent SOP：`docs/agent-sop-install.md`；Cursor Skill：`.cursor/skills/ohosxray-install/`
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
