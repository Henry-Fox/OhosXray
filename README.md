# OhosXray

HarmonyOS / OpenHarmony 上的 **VPN Extension + Xray-core** 集成示例工程。  
目标是演示如何在鸿蒙 `VpnExtensionAbility` 中接入 TUN，并把流量交给 Xray 用户态协议栈处理。

> **重要：本仓库是技术学习与研究示例，不是面向普通消费者的网络加速产品，也不提供任何规避网络审查的指导。**  
> 使用前请自行确认并遵守你所在地的法律法规与运营商规定。作者不对滥用导致的后果负责。

## 功能概览

- 全局 VPN（TUN）模式：系统流量经 `VpnExtensionAbility` 进入 Xray
- 本地代理模式：本机 SOCKS5 / HTTP（需手动配置系统或应用代理）
- 支持导入常见 `vmess://` / `vless://` 分享链接（以你的节点配置为准）
- Native：ArkTS + NAPI + Go `c-shared`（`libxraycore.so`）

技术栈与版本见 [`docs/tech-stack-with-versions.md`](docs/tech-stack-with-versions.md)。

## 安装与使用（最终用户）

### 能不能不开开发者模式？

**当前仓库默认产物是调试签名 HAP，通常不能。**

| 安装方式 | 是否需要开发者相关能力 | 说明 |
|----------|------------------------|------|
| `hdc install` / DevEco Run | **需要** 开发者模式 + USB 调试 | 本仓库默认路径 |
| 应用市场正式包 | 不需要开发者模式 | 需正式签名、资质与上架审核；**本示例默认不走这条路径** |
| 企业分发 / 内部 MDM | 视企业策略 | 需企业证书与分发通道 |

结论：

- **学习 / 自用调试**：请开启开发者模式，用 DevEco 或 `hdc` 安装。
- **给普通用户、不开开发者模式**：需要你自行申请正式发布证书并完成合规上架或企业分发；本仓库不提供绕过系统安装限制的方法。

### 从 Release 安装（调试签名）

1. 手机开启 **开发者模式** 与 **USB 调试**，用数据线连接电脑。  
2. 到本仓库 [Releases](../../releases) 下载 `*.hap`。  
3. 安装：

```bash
hdc install -r path/to/entry-default-signed.hap
```

4. 打开应用 → 添加节点 → 选择「全局 VPN」→ 连接。  
5. 首次连接系统会弹出 VPN 授权，请允许。

> `libxraycore.so` 已打进 HAP，普通安装一般 **不需要** 再单独下载 `.so`。  
> Release 中的 `libxraycore.so` 主要给从源码编译 HAP 的开发者使用。

## 从源码构建（开发者）

### 环境

- DevEco Studio / HarmonyOS SDK **26.0.0**（与 `compileSdkVersion` 对齐）
- Go **1.26.x**
- Windows 上交叉编译 Go 核心时使用 SDK 自带 OHOS clang（脚本已写好）

### 1. 签名配置

```bash
copy build-profile.json5.example build-profile.json5
```

用 DevEco 自动生成的调试签名信息填入 `build-profile.json5`（**不要提交该文件**）。

### 2. 编译 `libxraycore.so`

```powershell
cd native-core\go-shim
powershell -ExecutionPolicy Bypass -File .\build_ohos_arm64.ps1
```

产物会复制到：

- `entry/src/main/cpp/libs/arm64-v8a/`（供 CMake 链接）
- `entry/libs/arm64-v8a/`（打进 HAP）

也可直接从 Release 下载对应版本的 `libxraycore.so` 放到上述目录。

### 3. 编译并安装 HAP

DevEco 打开工程后 Build → 安装；或使用 hvigor 组装 HAP 后：

```bash
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
```

## 合规与风险说明（请认真阅读）

1. **法律**：网络代理 / VPN 类能力在不同地区受到不同程度的监管。请勿将本项目用于违法用途。本项目仅作鸿蒙系统能力与开源组件集成的示例。  
2. **上架**：面向大众分发前，请自行评估应用商店政策与资质要求；调试包不适合当作正式产品分发。  
3. **隐私与安全**：节点、证书、日志可能含敏感信息；请勿把真实节点、签名口令、用户流量日志提交到公开仓库。  
4. **责任**：因使用本软件产生的任何后果由使用者自行承担。

## 目录结构（简）

```
AppScope/                 应用级配置
entry/                    ArkTS UI、VpnExtension、NAPI 桥
native-core/go-shim/      Go c-shared 封装与交叉编译脚本
native-core/third_party/  本地 patch 依赖（如 gVisor Fstat 兼容）
docs/                     技术栈文档
```

## License

源码默认以 MIT 许可发布（见 `LICENSE`）。  
第三方组件（如 Xray-core、gVisor）遵循其各自许可证。
