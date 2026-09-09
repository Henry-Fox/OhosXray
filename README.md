# OhosXray

**鸿蒙（HarmonyOS）系统级 VPN** 示例工程：`VpnExtensionAbility`（TUN）+ Xray-core。  
面向 HarmonyOS NEXT 真机；也可参考用于 OpenHarmony 能力验证（扫码等 HMS 能力依赖 HarmonyOS）。

> **重要：本仓库是技术学习与研究示例，不是面向普通消费者的网络加速产品，也不提供任何规避网络审查的指导。**  
> 使用前请自行确认并遵守你所在地的法律法规与运营商规定。作者不对滥用导致的后果负责。

## 一句话定位

| 项 | 说明 |
|----|------|
| 是什么 | **鸿蒙系统 VPN**（系统授权的全局隧道），不是浏览器插件、也不是仅本机代理面板 |
| 主测机 | **HUAWEI Mate 80 Pro**（已实测安装脚本、全局 VPN、智能分流） |
| 怎么装 | 开发者模式 + USB 调试 → [`tools/install-ohosxray.bat`](tools/install-ohosxray.bat)（脚本已在主测机验证可用） |
| 熟人说明 | [`docs/install-for-friends.md`](docs/install-for-friends.md) |
| AI Agent | Cursor Skill：`.cursor/skills/ohosxray-install/`；SOP：[`docs/agent-sop-install.md`](docs/agent-sop-install.md) |

## 功能概览

- 全局 VPN（TUN）模式：系统流量经 `VpnExtensionAbility` 进入 Xray
- **默认智能分流**：系统层排除全量国内 IPv4 CIDR（直连不进 TUN），Xray 侧 `geosite:cn` / `geoip:cn` 兜底；可切换「全局代理」
- 扫码添加节点：HarmonyOS `ScanKit`（支持相册）
- 本地代理模式：本机 SOCKS5 / HTTP（需手动配置系统或应用代理）
- 支持导入常见 `vmess://` / `vless://` 分享链接（以你的节点配置为准）
- geoip / geosite / 国内 CIDR 列表可后台自动更新（约 24h）
- UI：浅绿主题 / 深色跟随系统、按钮图标、应用图标
- 切网自动重绑出口（WiFi ↔ 蜂窝）；日志滚动上限（避免无限涨）
- Native：ArkTS + NAPI + Go `c-shared`（`libxraycore.so`）

技术栈与版本见 [`docs/tech-stack-with-versions.md`](docs/tech-stack-with-versions.md)。  
朋友圈宣传文案与配图见 [`docs/moments-promo.md`](docs/moments-promo.md)。

## 安装与使用（最终用户）

### 能不能不开开发者模式？

**不能（本仓库路径下）。** 默认产物是调试签名 HAP。

| 安装方式 | 是否需要开发者相关能力 | 说明 |
|----------|------------------------|------|
| 半自动脚本 / `hdc install` / DevEco Run | **需要** 开发者模式 + USB 调试 | **本仓库唯一推荐路径** |
| 应用市场正式包 | 不需要开发者模式 | VPN/代理类国内上架极难；**本示例明确不走** |
| 企业分发 / 内部 MDM | 视企业策略 | 需企业证书；本仓库不提供 |

结论（写死）：

- **熟人 / 自用**：开开发者模式 → 用 [`tools/install-ohosxray.bat`](tools/install-ohosxray.bat) 半自动安装。说明见 [`docs/install-for-friends.md`](docs/install-for-friends.md)。  
- **Agent 代装**：遵循 [`docs/agent-sop-install.md`](docs/agent-sop-install.md)。  
- **不开开发者模式给陌生人正规商店包**：不在本项目范围内；也不提供绕过系统安装限制的方法。

### 半自动安装（推荐，已在 Mate 80 Pro 验证）

1. 手机开启 **开发者模式** 与 **USB 调试**，USB 连接电脑并点允许。  
2. 从 [Releases](https://github.com/Henry-Fox/OhosXray/releases) 下载 `*.hap`，放到仓库根目录或 `release\`。  
3. 双击：

```text
tools\install-ohosxray.bat
```

或：

```powershell
.\tools\install-ohosxray.ps1
.\tools\install-ohosxray.ps1 -HapPath .\release\your.hap
```

脚本会自动查找 `hdc`、检测已连接设备、对最新/指定 HAP 执行 `hdc install -r`。  
在 **Mate 80 Pro** 上按上述路径实测通过。

4. 打开应用 → 添加节点 → 「全局 VPN」→ 默认「智能分流」→ 连接 → 允许系统 **VPN** 授权。  
5. WiFi / 移动网络切换后会自动按新出口重连；若偶发失败，断开再连一次即可。

更细的步骤与排错见 [`docs/install-for-friends.md`](docs/install-for-friends.md)。

### 手动 hdc（等价）

```bash
hdc install -r path/to/entry-default-signed.hap
```

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
entry/                    ArkTS UI、鸿蒙 VpnExtension、NAPI 桥
native-core/go-shim/      Go c-shared 封装与交叉编译脚本
native-core/third_party/  本地 patch 依赖（如 gVisor Fstat 兼容）
tools/                    半自动安装脚本（bat / ps1）
docs/                     技术栈、熟人安装、Agent SOP
.cursor/skills/           Cursor Agent Skill（安装流程）
```

## License

源码默认以 MIT 许可发布（见 `LICENSE`）。  
第三方组件（如 Xray-core、gVisor）遵循其各自许可证。
