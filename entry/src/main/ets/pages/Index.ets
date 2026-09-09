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
import { UiTheme } from '../common/UiTheme';
import { UiIcon } from '../common/UiIcon';

const TAG = 'Index';
const SOCKS_LISTEN = '127.0.0.1';
const SOCKS_PORT = 10808;
const HTTP_LISTEN = '127.0.0.1';
const HTTP_PORT = 10809;

type RunMode = 'vpn' | 'local';

interface LatencyEntry {
  id: string;
  ms: number;
}

@Entry
@Component
struct Index {
  @State servers: ServerProfile[] = [];
  @State activeId: string = '';
  @State connected: boolean = false;
  @State runMode: RunMode = 'vpn';
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

  private async startLocal(profile: ServerProfile): Promise<void> {
    try {
      const configJson = buildXrayConfig(profile, {
        mode: 'local',
        socksListen: SOCKS_LISTEN,
        socksPort: SOCKS_PORT,
        httpListen: HTTP_LISTEN,
        httpPort: HTTP_PORT
      });
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
        fontColor: UiTheme.destructive,
        action: () => {
          this.doDeleteServer(item.id).catch((e: Error) => {
            Logger.error(TAG, `delete server failed: ${e.message}`);
          });
        }
      },
      secondaryButton: { value: '取消', action: () => {} }
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
    if (this.testingId !== '') {
      return;
    }
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
    if (this.testingId === id) {
      return '测速中';
    }
    const ms = this.getLatencyMs(id);
    if (ms === undefined) {
      return '未测速';
    }
    if (ms < 0) {
      return '超时';
    }
    return `${ms}ms`;
  }

  private latencyColor(id: string): ResourceColor {
    if (this.testingId === id) {
      return UiTheme.mutedFg;
    }
    const ms = this.getLatencyMs(id);
    if (ms === undefined || ms < 0) {
      return UiTheme.mutedFg;
    }
    if (ms < 150) {
      return UiTheme.primary;
    }
    if (ms < 300) {
      return UiTheme.warn;
    }
    return UiTheme.destructive;
  }

  build() {
    Column() {
      Row() {
        Text('节点')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor(UiTheme.fg)
          .layoutWeight(1)

        Button({ type: ButtonType.Normal }) {
          Row({ space: 6 }) {
            UiIcon({ src: $r('app.media.ic_log'), iconSize: 16, color: UiTheme.fg })
            Text('日志').fontSize(13).fontWeight(FontWeight.Medium).fontColor(UiTheme.fg)
          }
        }
        .height(36)
        .padding({ left: 14, right: 14 })
        .borderRadius(UiTheme.radiusPill)
        .backgroundColor(UiTheme.secondary)
        .margin({ right: 8 })
        .onClick(() => { router.pushUrl({ url: 'pages/LogView' }); })

        Button({ type: ButtonType.Normal }) {
          Row({ space: 6 }) {
            UiIcon({ src: $r('app.media.ic_plus'), iconSize: 16, color: UiTheme.primaryFg })
            Text('添加').fontSize(13).fontWeight(FontWeight.Medium).fontColor(UiTheme.primaryFg)
          }
        }
        .height(36)
        .padding({ left: 14, right: 14 })
        .borderRadius(UiTheme.radiusPill)
        .backgroundColor(UiTheme.primary)
        .onClick(() => { router.pushUrl({ url: 'pages/ServerEdit' }); })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 20, bottom: 12 })

      Column({ space: 12 }) {
        Row() {
          Text('运行模式').width(72).fontSize(13).fontWeight(FontWeight.Medium).fontColor(UiTheme.mutedFg)
          Row() {
            Text('全局 VPN')
              .layoutWeight(1).textAlign(TextAlign.Center).fontSize(13).fontWeight(FontWeight.Medium)
              .fontColor(this.runMode === 'vpn' ? UiTheme.primaryFg : UiTheme.mutedFg)
              .backgroundColor(this.runMode === 'vpn' ? UiTheme.primary : Color.Transparent)
              .borderRadius(UiTheme.radiusPill).padding({ top: 8, bottom: 8 })
              .onClick(() => { this.runMode = 'vpn'; })
            Text('本地代理')
              .layoutWeight(1).textAlign(TextAlign.Center).fontSize(13).fontWeight(FontWeight.Medium)
              .fontColor(this.runMode === 'local' ? UiTheme.primaryFg : UiTheme.mutedFg)
              .backgroundColor(this.runMode === 'local' ? UiTheme.primary : Color.Transparent)
              .borderRadius(UiTheme.radiusPill).padding({ top: 8, bottom: 8 })
              .onClick(() => { this.runMode = 'local'; })
          }
          .layoutWeight(1).padding(4).backgroundColor(UiTheme.muted).borderRadius(UiTheme.radiusPill)
        }
        .width('100%').alignItems(VerticalAlign.Center)

        if (this.runMode === 'vpn') {
          Row() {
            Text('分流策略').width(72).fontSize(13).fontWeight(FontWeight.Medium).fontColor(UiTheme.mutedFg)
            Row() {
              Text('智能分流')
                .layoutWeight(1).textAlign(TextAlign.Center).fontSize(13).fontWeight(FontWeight.Medium)
                .fontColor(this.smartRoute ? UiTheme.primaryFg : UiTheme.mutedFg)
                .backgroundColor(this.smartRoute ? UiTheme.primary : Color.Transparent)
                .borderRadius(UiTheme.radiusPill).padding({ top: 8, bottom: 8 })
                .onClick(() => { this.smartRoute = true; })
              Text('全局代理')
                .layoutWeight(1).textAlign(TextAlign.Center).fontSize(13).fontWeight(FontWeight.Medium)
                .fontColor(!this.smartRoute ? UiTheme.primaryFg : UiTheme.mutedFg)
                .backgroundColor(!this.smartRoute ? UiTheme.primary : Color.Transparent)
                .borderRadius(UiTheme.radiusPill).padding({ top: 8, bottom: 8 })
                .onClick(() => { this.smartRoute = false; })
            }
            .layoutWeight(1).padding(4).backgroundColor(UiTheme.muted).borderRadius(UiTheme.radiusPill)
          }
          .width('100%').alignItems(VerticalAlign.Center)
        }
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 8 })

      if (this.servers.length === 0) {
        Column({ space: 12 }) {
          Column() {
            UiIcon({ src: $r('app.media.ic_signal'), iconSize: 28, color: UiTheme.mutedFg })
          }
          .width(64).height(64).justifyContent(FlexAlign.Center)
          .borderRadius(UiTheme.radiusCard).backgroundColor(UiTheme.muted)

          Text('还没有节点').fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiTheme.fg)
          Text('点击右上角「添加」导入你的第一个节点').fontSize(12).fontColor(UiTheme.mutedFg)

          Button({ type: ButtonType.Normal }) {
            Row({ space: 6 }) {
              UiIcon({ src: $r('app.media.ic_plus'), iconSize: 16, color: UiTheme.primaryFg })
              Text('添加节点').fontSize(13).fontWeight(FontWeight.Medium).fontColor(UiTheme.primaryFg)
            }
          }
          .height(40).padding({ left: 20, right: 20 })
          .borderRadius(UiTheme.radiusPill).backgroundColor(UiTheme.primary).margin({ top: 4 })
          .onClick(() => { router.pushUrl({ url: 'pages/ServerEdit' }); })
        }
        .layoutWeight(1).justifyContent(FlexAlign.Center).width('100%').padding({ bottom: 80 })
      } else {
        List({ space: 12 }) {
          ForEach(this.servers, (item: ServerProfile) => {
            ListItem() {
              Column() {
                Row({ space: 12 }) {
                  Radio({ value: item.id, group: 'server' })
                    .checked(item.id === this.activeId)
                    .radioStyle({
                      checkedBackgroundColor: UiTheme.primary,
                      uncheckedBorderColor: UiTheme.dotOff
                    })
                    .onChange((checked: boolean) => {
                      if (checked) { this.onSelect(item.id); }
                    })
                  Column({ space: 2 }) {
                    Text(item.remark)
                      .fontSize(15).fontWeight(FontWeight.Medium).fontColor(UiTheme.fg)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(`${item.protocol} · ${item.address}:${item.port}`)
                      .fontSize(12).fontColor(UiTheme.mutedFg).fontFamily('monospace')
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .alignItems(HorizontalAlign.Start).layoutWeight(1)

                  Text(this.latencyText(item.id))
                    .fontSize(12).fontWeight(FontWeight.Medium)
                    .fontColor(this.latencyColor(item.id)).fontFamily('monospace')
                    .backgroundColor(UiTheme.muted).borderRadius(UiTheme.radiusPill)
                    .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                }
                .width('100%')

                Divider().color(UiTheme.border).margin({ top: 12, bottom: 8 })

                Row() {
                  Blank()
                  Row({ space: 4 }) {
                    UiIcon({
                      src: $r('app.media.ic_gauge'),
                      iconSize: 15,
                      color: this.testingId === item.id ? UiTheme.mutedFg : UiTheme.accent
                    })
                    Text(this.testingId === item.id ? '测速中…' : '测速')
                      .fontSize(13).fontWeight(FontWeight.Medium)
                      .fontColor(this.testingId === item.id ? UiTheme.mutedFg : UiTheme.accent)
                  }
                  .padding({ left: 10, right: 10, top: 6, bottom: 6 }).borderRadius(8)
                  .onClick(() => { this.testLatency(item); })

                  Row({ space: 4 }) {
                    UiIcon({ src: $r('app.media.ic_pencil'), iconSize: 15, color: UiTheme.mutedFg })
                    Text('编辑').fontSize(13).fontWeight(FontWeight.Medium).fontColor(UiTheme.mutedFg)
                  }
                  .padding({ left: 10, right: 10, top: 6, bottom: 6 }).borderRadius(8)
                  .onClick(() => { this.onEditServer(item); })

                  Row({ space: 4 }) {
                    UiIcon({ src: $r('app.media.ic_trash'), iconSize: 15, color: UiTheme.destructive })
                    Text('删除').fontSize(13).fontWeight(FontWeight.Medium).fontColor(UiTheme.destructive)
                  }
                  .padding({ left: 10, right: 4, top: 6, bottom: 6 }).borderRadius(8)
                  .onClick(() => { this.onDeleteServer(item); })
                }
                .width('100%')
              }
              .width('100%').padding(16).backgroundColor(UiTheme.card)
              .borderRadius(UiTheme.radiusCard)
              .border({
                width: item.id === this.activeId ? 1.5 : 1,
                color: item.id === this.activeId ? UiTheme.selectedBorder : UiTheme.border
              })
            }
          }, (item: ServerProfile) => item.id)
        }
        .layoutWeight(1).width('100%')
        .padding({ left: 20, right: 20, top: 4, bottom: 8 })
        .scrollBar(BarState.Off)
      }

      Column({ space: 6 }) {
        if (this.runMode === 'vpn') {
          Row({ space: 8 }) {
            Circle({ width: 10, height: 10 })
              .fill(this.connected ? UiTheme.primary : UiTheme.dotOff)
            Text(this.connected ? 'VPN 已连接' : 'VPN 未连接')
              .fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor(this.connected ? UiTheme.fg : UiTheme.mutedFg)
            Text('·').fontColor(UiTheme.mutedFg)
            Text(this.smartRoute ? '智能分流' : '全局代理')
              .fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiTheme.primary)
          }
          Text(this.smartRoute ? '国内直连，其余走代理' : '所有流量均通过代理节点')
            .fontSize(12).fontColor(UiTheme.mutedFg)
        } else if (this.connected) {
          Text('本机代理已启动').fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiTheme.fg)
          Row({ space: 8 }) {
            Text(`HTTP  ${HTTP_LISTEN}:${HTTP_PORT}`).fontSize(12).fontColor(UiTheme.mutedFg).fontFamily('monospace')
            Text('复制').fontSize(12).fontColor(UiTheme.accent)
              .onClick(() => { this.copyProxyAddress(`${HTTP_LISTEN}:${HTTP_PORT}`); })
          }
          Row({ space: 8 }) {
            Text(`SOCKS5  ${SOCKS_LISTEN}:${SOCKS_PORT}`).fontSize(12).fontColor(UiTheme.mutedFg).fontFamily('monospace')
            Text('复制').fontSize(12).fontColor(UiTheme.accent)
              .onClick(() => { this.copyProxyAddress(`${SOCKS_LISTEN}:${SOCKS_PORT}`); })
          }
        } else {
          Text('本地代理未启动').fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiTheme.mutedFg)
          Text('需在系统或应用中手动填写代理地址').fontSize(12).fontColor(UiTheme.mutedFg)
        }

        Button({ type: ButtonType.Normal }) {
          Row({ space: 8 }) {
            UiIcon({ src: $r('app.media.ic_power'), iconSize: 20, color: UiTheme.primaryFg })
            Text(this.connected ? '断开' : '连接')
              .fontSize(16).fontWeight(FontWeight.Bold).fontColor(UiTheme.primaryFg)
          }
        }
        .width('100%').height(52).borderRadius(UiTheme.radiusBtn)
        .backgroundColor(this.connected ? UiTheme.destructive : UiTheme.primary)
        .enabled(this.connected || this.activeId !== '')
        .opacity((this.connected || this.activeId !== '') ? 1 : 0.45)
        .margin({ top: 8 })
        .onClick(() => { this.onToggleConnect(); })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 12, bottom: 28 })
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(UiTheme.bg)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(UiTheme.bg)
  }
}