# 给熟人安装 OhosXray（半自动）

> **写死的定位（请先读）**  
> - 本项目默认只提供 **调试签名 HAP**。  
> - **不能**指望在国内应用市场给陌生人「点一下就装」的正式包（VPN/代理类合规与审核门槛极高；本仓库也不走上架路径）。  
> - **不开开发者模式，就无法用本仓库的常规方式安装。**  
> - 半自动脚本只帮你省掉手敲 `hdc`，**不绕过**系统安装限制。

## 你需要准备

| 物品 | 说明 |
|------|------|
| Windows 电脑 | 已装 [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/) 或至少带 `hdc` 的 HarmonyOS SDK |
| USB 数据线 | 能传数据（充电线可能不行） |
| 调试签名 HAP | 从 GitHub [Releases](https://github.com/Henry-Fox/OhosXray/releases) 下载，或自己用 DevEco 编出来 |
| 本仓库里的脚本 | `tools\install-ohosxray.bat` / `tools\install-ohosxray.ps1` |

## 手机端（一次性）

1. **设置 → 关于本机** → 连续点击「版本号」直到提示已进入开发者模式。  
2. 回到设置 → **系统 → 开发人员选项**（名称因机型略有差异）→ 打开 **USB 调试**。  
3. 用数据线连上电脑；手机弹窗选 **允许 USB 调试**。

## 电脑端（每次装/更新）

1. 把下载的 `*.hap` 放到仓库根目录，或 `release\` 文件夹。  
2. 双击运行：

```text
tools\install-ohosxray.bat
```

或在 PowerShell 中：

```powershell
cd D:\Project\OhosXray   # 改成你的仓库路径
.\tools\install-ohosxray.ps1
# 或指定文件：
.\tools\install-ohosxray.ps1 -HapPath .\release\entry-default-signed.hap
```

3. 看到「安装完成」后，在手机打开应用 → 添加节点 → **全局 VPN**（默认 **智能分流**）→ 连接 → 允许 VPN 授权。

## 常见问题

| 现象 | 处理 |
|------|------|
| 脚本说没有设备 | 检查 USB 调试、换线/换口、手机点「允许」；命令行执行 `hdc list targets` |
| 多台设备 | `.\tools\install-ohosxray.ps1 -Device <序列号>` |
| 安装失败 / 签名冲突 | 先在手机卸载旧版 OhosXray，再重装 |
| 找不到 hdc | 安装 DevEco / SDK，或把 `...\Sdk\<ver>\toolchains` 加入 PATH |
| WiFi 和流量来回切用不了 | 新版本会自动重连；仍不行则在应用内断开再连接一次 |

## 明确做不到的事

- 不提供「不开开发者模式」的破解安装方式。  
- 不提供应用市场上架包与规避审核的指导。  
- 不保证任意第三方改装系统/刷机环境下的兼容性。

更多技术细节见 [`tech-stack-with-versions.md`](./tech-stack-with-versions.md)。  
若由 Cursor Agent 代装，请遵循 [`agent-sop-install.md`](./agent-sop-install.md)。
