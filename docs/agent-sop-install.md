# Agent SOP：为用户安装 OhosXray（调试 HAP）

面向 Cursor / Codex 等 Agent。按顺序执行；**不要跳过失败检查**。

配套 Cursor Skill：`.cursor/skills/ohosxray-install/SKILL.md`（触发安装类请求时优先加载本 SOP）。

## 0. 硬约束（必须遵守）

1. 先向用户标明：这是 **鸿蒙（HarmonyOS）系统级 VPN**（`VpnExtensionAbility` / TUN），不是普通本机代理 App。  
2. 本仓库产物是 **调试签名 HAP**，接收方必须 **开发者模式 + USB 调试**。  
3. **禁止**协助绕过系统安装限制、伪造正式签名、规避应用市场审核。  
4. 若用户要求「给陌生人不开开发者模式的正式包」：说明国内公开上架不现实，引导读 `docs/install-for-friends.md`，停止安装类越权方案。  
5. 未获用户明确要求时：**不要** `git commit` / `git push` / 改签名口令。  
6. **主测机：HUAWEI Mate 80 Pro**；脚本与 VPN 流程已在该机验证。其他机型先按本 SOP 装，兼容问题如实汇报。

## 1. 前置检查

在仓库根目录执行（Windows PowerShell）：

```powershell
pwd
Test-Path .\tools\install-ohosxray.ps1
Get-Command hdc -ErrorAction SilentlyContinue
# 或脚本内置查找；也可：
# Get-ChildItem "$env:LOCALAPPDATA\OpenHarmony\Sdk\*\toolchains\hdc.exe"
```

确认：

- [ ] 当前目录是 OhosXray 仓库根（含 `entry/`、`docs/`、`tools/`）  
- [ ] 存在待装 `*.hap`（Release 下载到 `release\` 或根目录，或 DevEco 输出目录）  
- [ ] 能找到 `hdc`

若无 HAP：告知用户从 GitHub Releases 下载，或协助用 DevEco 构建；**不要假装安装成功**。

## 2. 设备连通

```powershell
hdc list targets
```

期望：至少一行设备序列号。若为空：

1. 请用户开开发者模式、USB 调试、点允许  
2. 换线/口后重试  
3. 仍失败则停止并汇报，不要反复盲试超过 3 次无新信息的命令

多设备时：问用户选哪台，或使用 `-Device <serial>`。

## 3. 执行安装

优先一键脚本：

```powershell
Set-Location <repo-root>
.\tools\install-ohosxray.ps1
# 或
.\tools\install-ohosxray.ps1 -HapPath <绝对或相对路径.hap> -Device <可选序列号>
```

成功判据：脚本退出码 0，且输出含「安装完成」或 hdc 显示 install 成功。

失败时按脚本/hdc 原文排查：

| 线索 | 动作 |
|------|------|
| 签名/已存在冲突 | 请用户卸载旧包后重跑 |
| unauthorized / 未授权 | 手机点允许 USB 调试 |
| no targets | 回到第 2 步 |
| 文件损坏/找不到 | 重新下载 HAP，校验路径 |

## 4. 安装后验收（口头指导即可）

请用户在手机上：

1. 打开 OhosXray  
2. 添加/选择节点  
3. 运行模式：**全局 VPN**；分流：**智能分流**（默认）  
4. 点连接 → 允许 VPN  
5. 测国内站应直连较顺；国外依赖节点  
6. 切换 WiFi ↔ 蜂窝：应在约数秒内自动重连；不行则断开再连，并抓日志（应用内「日志」或 `app.log`）

## 5. 向用户汇报模板

```text
安装结果：成功 / 失败
设备：<serial 或「未检测到」>
HAP：<路径>
后续：打开应用 → VPN + 智能分流 → 连接
限制说明：调试包，需开发者模式；无商店正式分发路径
```

## 6. 相关路径

| 文件 | 用途 |
|------|------|
| `tools/install-ohosxray.ps1` | 半自动安装主逻辑（Mate 80 Pro 已验） |
| `tools/install-ohosxray.bat` | 双击入口 |
| `docs/install-for-friends.md` | 熟人可读说明 |
| `docs/tech-stack-with-versions.md` | 技术栈与切网重连约定 |
| `.cursor/skills/ohosxray-install/SKILL.md` | Cursor Agent Skill |
| `README.md` | 总览与合规声明（标明鸿蒙 VPN） |
