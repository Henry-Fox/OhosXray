import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { ServerProfile } from '../model/ServerProfile';
import { serverStore } from '../common/ServerStore';
import { xrayBridge } from '../bridge/XrayBridge';
import { vpnController } from '../common/VpnController';
import { buildXrayConfig } from '../model/XrayConfigBuilder';
import { Logger } from '../common/Logger';

const TAG = 'Index';

// 本地代理模式的监听地址
const SOCKS_LISTEN = '127.0.0.1';
const SOCKS_PORT = 10808;
const HTTP_LISTEN = '127.0.0.1';
const HTTP_PORT = 10809;

type RunMode = 'vpn' | 'local';

interface LatencyEntry {
  id: string;
  ms: number; // -1 = timeout/error
}

@Entry
@Component
struct Index {
  @State servers: ServerProfile[] = [];
  @State activeId: string = '';
  @State connected: boolean = false;
  @State runMode: RunMode = 'vpn'; // 默认全局 VPN 模式
  /** VPN 默认智能分流：国内直连，其余走代理 */
  @State smartRoute: boolean = true;
  @State latencies: LatencyEntry[] = [];
  @State testingId: string = '';

  async aboutToAppear(): Promise<void> {
    await this.refreshServers();
  }

  onPageShow(): void {
    this.refreshServers().catch((e: Error) => {
      Logger.error(TAG, `refreshServers failed: ${e.message}`);
    });
  }

  private async refreshServers(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    await serverStore.init(context);
    this.servers = await serverStore.listServers();
    const savedId = await serverStore.getActiveServerId();
    if (savedId && this.servers.some(s => s.id === savedId)) {
      this.activeId = savedId;
    } else if (this.servers.length > 0) {
      this.activeId = this.servers[0].id;
      await serverStore.setActiveServerId(this.activeId);
    } else {
      this.activeId = '';
    }
    // 本地模式下 xray 跑在本进程，可直接查询状态
    if (this.runMode === 'local') {
      this.connected = xrayBridge.isRunning();
    }
  }

  private async onToggleConnect(): Promise<void> {
    const active = this.servers.find(s => s.id === this.activeId);
    const context = getContext(this) as common.UIAbilityContext;

    if (!this.connected) {
      if (!active) {
        promptAction.showToast({ message: '请先添加并选中一个节点', duration: 2000 });
        return;
      }
      if (this.runMode === 'vpn') {
        await this.startVpn(context, active);
      } else {
        await this.startLocal(active);
      }
    } else {
      if (this.runMode === 'vpn') {
        await this.stopVpn(context);
      } else {
        this.stopLocal();
      }
    }
  }

  // ── 全局 VPN 模式 ──────────────────────────────────────────────
  private async startVpn(context: common.UIAbilityContext, profile: ServerProfile): Promise<void> {
    try {
      await vpnController.start(context, profile, this.smartRoute);
      this.connected = true;
      const tip = this.smartRoute ? '智能分流已启动（国内直连）' : '全局代理已启动';
      promptAction.showToast({ message: tip, duration: 2500 });
    } catch (e) {
      Logger.error(TAG, `startVpn failed: ${Logger.stringifyError(e as Error)}`);
      promptAction.showToast({ message: `VPN 启动失败: ${Logger.stringifyError(e as Error)}`, duration: 3000 });
    }
  }

  private async stopVpn(context: common.UIAbilityContext): Promise<void> {
    try {
      await vpnController.stop(context);
      this.connected = false;
      promptAction.showToast({ message: '已断开', duration: 1500 });
    } catch (e) {
      Logger.error(TAG, `stopVpn failed: ${Logger.stringifyError(e as Error)}`);
      promptAction.showToast({ message: `断开失败: ${Logger.stringifyError(e as Error)}`, duration: 3000 });
    }
  }

  // ── 本地代理模式 ──────────────────────────────────────────────
  private async startLocal(profile: ServerProfile): Promise<void> {
    try {
      const configJson = buildXrayConfig(profile, {
        mode: 'local',
        socksListen: SOCKS_LISTEN,
        socksPort: SOCKS_PORT,
        httpListen: HTTP_LISTEN,
        httpPort: HTTP_PORT
      });
      Logger.info(TAG, `local xray config length=${configJson.length}`);
      const ok = xrayBridge.start(configJson, 0);
      if (!ok) {
        promptAction.showToast({ message: '启动失败，请查看日志', duration: 3000 });
        return;
      }
      this.connected = true;
      promptAction.showToast({ message: '本机代理已启动', duration: 2500 });
    } catch (e) {
      Logger.error(TAG, `startLocal failed: ${Logger.stringifyError(e as Error)}`);
      promptAction.showToast({ message: `连接失败: ${Logger.stringifyError(e as Error)}`, duration: 3000 });
    }
  }

  private stopLocal(): void {
    xrayBridge.stop();
    this.connected = false;
    promptAction.showToast({ message: '已停止', duration: 1500 });
  }

  private async copyProxyAddress(text: string): Promise<void> {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      promptAction.showToast({ message: '已复制代理地址', duration: 1500 });
    } catch (e) {
      Logger.error(TAG, `copy proxy address failed: ${Logger.stringifyError(e as Error)}`);
    }
  }

  private async onSelect(id: string): Promise<void> {
    this.activeId = id;
    await serverStore.setActiveServerId(id);
  }

  private onEditServer(item: ServerProfile): void {
    router.pushUrl({ url: 'pages/ServerEdit', params: { profileId: item.id } });
  }

  private onDeleteServer(item: ServerProfile): void {
    AlertDialog.show({
      title: '确认删除',
      message: `删除节点"${item.remark}"？`,
      primaryButton: {
        value: '删除',
        fontColor: '#E74C3C',
        action: () => {
          this.doDeleteServer(item.id).catch((e: Error) => {
            Logger.error(TAG, `delete server failed: ${e.message}`);
          });
        }
      },
      secondaryButton: {
        value: '取消',
        action: () => {}
      }
    });
  }

  private async doDeleteServer(id: string): Promise<void> {
    await serverStore.removeServer(id);
    if (this.activeId === id) {
      this.activeId = '';
      await serverStore.setActiveServerId('');
    }
    this.servers = this.servers.filter(s => s.id !== id);
    this.latencies = this.latencies.filter(l => l.id !== id);
  }

  private async testLatency(profile: ServerProfile): Promise<void> {
    if (this.testingId !== '') return;
    this.testingId = profile.id;
    const start = Date.now();
    const httpReq = http.createHttp();
    try {
      await httpReq.request(`http://${profile.address}:${profile.port}/`, {
        method: http.RequestMethod.GET,
        connectTimeout: 3000,
        readTimeout: 500,
      });
      this.updateLatency(profile.id, Date.now() - start);
    } catch (_e) {
      const elapsed = Date.now() - start;
      this.updateLatency(profile.id, elapsed < 2800 ? elapsed : -1);
    } finally {
      httpReq.destroy();
      this.testingId = '';
    }
  }

  private updateLatency(id: string, ms: number): void {
    const existing = this.latencies.findIndex(l => l.id === id);
    if (existing >= 0) {
      const updated: LatencyEntry[] = [...this.latencies];
      updated[existing] = { id, ms };
      this.latencies = updated;
    } else {
      this.latencies = [...this.latencies, { id, ms }];
    }
  }

  private getLatencyMs(id: string): number | undefined {
    return this.latencies.find(l => l.id === id)?.ms;
  }

  private latencyText(id: string): string {
    const ms = this.getLatencyMs(id);
    if (ms === undefined) return '';
    if (ms < 0) return '超时';
    return `${ms}ms`;
  }

  private latencyColor(id: string): string {
    const ms = this.getLatencyMs(id);
    if (ms === undefined || ms < 0) return '#E74C3C';
    if (ms < 200) return '#27AE60';
    if (ms < 500) return '#E67E22';
    return '#E74C3C';
  }

  build() {
    Column() {
      // ── Header ──────────────────────────────────────────────
      Row() {
        Text('节点')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
        Button('日志', { type: ButtonType.Normal })
          .fontSize(14)
          .height(34)
          .padding({ left: 16, right: 16 })
          .borderRadius(6)
          .backgroundColor('#999999')
          .margin({ right: 8 })
          .onClick(() => { router.pushUrl({ url: 'pages/LogView' }); })
        Button('添加', { type: ButtonType.Normal })
          .fontSize(14)
          .height(34)
          .padding({ left: 16, right: 16 })
          .borderRadius(6)
          .backgroundColor('#2ECC71')
          .onClick(() => { router.pushUrl({ url: 'pages/ServerEdit' }); })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 8 })

      // ── 模式切换 ────────────────────────────────────────────
      Row() {
        Text('运行模式')
          .fontSize(13)
          .fontColor('#666666')
          .margin({ right: 12 })
        Text('全局 VPN')
          .fontSize(13)
          .fontColor(this.runMode === 'vpn' ? '#FFFFFF' : '#666666')
          .backgroundColor(this.runMode === 'vpn' ? '#2ECC71' : '#EEEEEE')
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          .borderRadius(16)
          .onClick(() => { this.runMode = 'vpn'; })
        Text('本地代理')
          .fontSize(13)
          .fontColor(this.runMode === 'local' ? '#FFFFFF' : '#666666')
          .backgroundColor(this.runMode === 'local' ? '#3498DB' : '#EEEEEE')
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          .borderRadius(16)
          .margin({ left: 8 })
          .onClick(() => { this.runMode = 'local'; })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 4 })

      // ── 分流策略（仅 VPN）──────────────────────────────────
      if (this.runMode === 'vpn') {
        Row() {
          Text('分流策略')
            .fontSize(13)
            .fontColor('#666666')
            .margin({ right: 12 })
          Text('智能分流')
            .fontSize(13)
            .fontColor(this.smartRoute ? '#FFFFFF' : '#666666')
            .backgroundColor(this.smartRoute ? '#2ECC71' : '#EEEEEE')
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            .borderRadius(16)
            .onClick(() => { this.smartRoute = true; })
          Text('全局代理')
            .fontSize(13)
            .fontColor(!this.smartRoute ? '#FFFFFF' : '#666666')
            .backgroundColor(!this.smartRoute ? '#2ECC71' : '#EEEEEE')
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            .borderRadius(16)
            .margin({ left: 8 })
            .onClick(() => { this.smartRoute = false; })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 8 })
      }

      // ── Server list ─────────────────────────────────────────
      if (this.servers.length === 0) {
        Column({ space: 8 }) {
          Text('暂无节点').fontColor('#999999').fontSize(16)
          Text('点击右上角「添加」按钮导入节点').fontColor('#BBBBBB').fontSize(13)
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .width('100%')
      } else {
        List() {
          ForEach(this.servers, (item: ServerProfile) => {
            ListItem() {
              Column() {
                // ── Top row: radio + name + latency badge ────
                Row({ space: 8 }) {
                  Radio({ value: item.id, group: 'server' })
                    .checked(item.id === this.activeId)
                    .onChange((checked: boolean) => {
                      if (checked) { this.onSelect(item.id); }
                    })
                  Column({ space: 2 }) {
                    Text(item.remark)
                      .fontSize(15)
                      .fontWeight(FontWeight.Medium)
                      .maxLines(1)
                    Text(`${item.protocol} · ${item.address}:${item.port}`)
                      .fontSize(12)
                      .fontColor('#999999')
                      .maxLines(1)
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  if (this.getLatencyMs(item.id) !== undefined) {
                    Text(this.latencyText(item.id))
                      .fontSize(12)
                      .fontColor(this.latencyColor(item.id))
                      .backgroundColor('#F5F5F5')
                      .borderRadius(4)
                      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  }
                }
                .width('100%')
                .padding({ left: 12, right: 12, top: 10, bottom: 4 })

                // ── Bottom row: action buttons ───────────────
                Row() {
                  Blank()
                  Text(this.testingId === item.id ? '测速中…' : '测速')
                    .fontSize(13)
                    .fontColor(this.testingId === item.id ? '#AAAAAA' : '#3498DB')
                    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                    .onClick(() => { this.testLatency(item); })
                  Text('编辑')
                    .fontSize(13)
                    .fontColor('#555555')
                    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                    .onClick(() => { this.onEditServer(item); })
                  Text('删除')
                    .fontSize(13)
                    .fontColor('#E74C3C')
                    .padding({ left: 10, right: 14, top: 5, bottom: 5 })
                    .onClick(() => { this.onDeleteServer(item); })
                }
                .width('100%')
                .padding({ bottom: 4 })
              }
              .width('100%')
              .backgroundColor(item.id === this.activeId ? '#F0FFF4' : '#FFFFFF')
            }
          }, (item: ServerProfile) => item.id)
        }
        .layoutWeight(1)
        .width('100%')
        .divider({ strokeWidth: 0.5, color: '#EEEEEE', startMargin: 12, endMargin: 12 })
      }

      // ── Connect area ─────────────────────────────────────────
      Column({ space: 8 }) {
        if (this.connected) {
          if (this.runMode === 'vpn') {
            Text(this.smartRoute ? '● VPN 已连接 · 智能分流' : '● VPN 已连接 · 全局代理')
              .fontColor('#27AE60')
              .fontSize(14)
            Text(this.smartRoute ? '国内直连，其余走代理' : '所有流量走代理')
              .fontSize(12)
              .fontColor('#999999')
          } else {
            Text('● 本机代理已启动')
              .fontColor('#27AE60')
              .fontSize(14)
            Row({ space: 8 }) {
              Text(`HTTP  ${HTTP_LISTEN}:${HTTP_PORT}`)
                .fontSize(13)
                .fontColor('#666666')
              Text('复制')
                .fontSize(13)
                .fontColor('#3498DB')
                .onClick(() => { this.copyProxyAddress(`${HTTP_LISTEN}:${HTTP_PORT}`); })
            }
            Row({ space: 8 }) {
              Text(`SOCKS5  ${SOCKS_LISTEN}:${SOCKS_PORT}`)
                .fontSize(13)
                .fontColor('#666666')
              Text('复制')
                .fontSize(13)
                .fontColor('#3498DB')
                .onClick(() => { this.copyProxyAddress(`${SOCKS_LISTEN}:${SOCKS_PORT}`); })
            }
            Text('系统 WLAN 手动代理只支持 HTTP，请填 HTTP 地址；浏览器自带代理设置一般支持 SOCKS5')
              .fontSize(11)
              .fontColor('#999999')
              .textAlign(TextAlign.Center)
              .width('85%')
          }
        }
        Button(this.connected ? '断开' : '连接')
          .width('90%')
          .height(50)
          .fontSize(17)
          .backgroundColor(this.connected ? '#E74C3C' : (this.runMode === 'vpn' ? '#2ECC71' : '#3498DB'))
          .onClick(() => { this.onToggleConnect(); })
      }
      .padding({ top: 12, bottom: 32 })
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }
}
