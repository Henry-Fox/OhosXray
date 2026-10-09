import { VpnExtensionAbility } from '@kit.NetworkKit';
import { vpnExtension } from '@kit.NetworkKit';
import { connection } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import fs from '@ohos.file.fs';
import { Logger } from '../common/Logger';
import { GeoAssetHelper } from '../common/GeoAssetHelper';
import { CnRouteHelper } from '../common/CnRouteHelper';
import { serverStore } from '../common/ServerStore';
import { xrayBridge } from '../bridge/XrayBridge';
import { buildXrayConfig } from '../model/XrayConfigBuilder';
import { ServerProfile } from '../model/ServerProfile';

const TAG = 'ProxyVpnAbility';

// ── VpnConfig 类型（对齐 @kit.NetworkKit vpnExtension / connection）────────
interface NetAddr {
  address: string;
  family: number; // 1=IPv4, 2=IPv6
  port?: number;
}
interface AddressWithPrefix {
  address: NetAddr;
  prefixLength: number;
}
interface RouteInfo {
  interface: string;
  destination: AddressWithPrefix;
  gateway: NetAddr;
  hasGateway: boolean;
  isDefaultRoute: boolean;
  isExcludedRoute?: boolean;
}
interface VpnConfig {
  vpnId?: string;
  addresses: AddressWithPrefix[];
  routes: RouteInfo[];
  mtu: number;
  dnsAddresses: string[];
  isIPv4Accepted: boolean;
  /** 与 blockedApplications 互斥，勿同时设置（鸿蒙 7 上同时传空白名单会导致无 App 走 VPN） */
  trustedApplications?: string[];
  blockedApplications?: string[];
}

const TUN_IPV4 = '172.19.0.1';
const TUN_IPV4_PREFIX = 30;
const MTU = 1500;

const LOG_PUMP_INTERVAL_MS = 2000;
/** Xray error/access 日志滚动上限 */
const XRAY_LOG_MAX_SIZE = 1024 * 1024; // 1MB
/** 单次泵入 app.log 的最大增量，避免偶发巨量刷屏 */
const LOG_PUMP_CHUNK_MAX = 12000;

/** 切网防抖：WiFi/蜂窝抖动时等链路稳定再重建 */
const NET_RECONNECT_DEBOUNCE_MS = 4500;
/** 轮询兜底：部分机型 NetConnection 在 VPN 下不回调 */
const NET_POLL_INTERVAL_MS = 2500;
/** destroy 后 recreate 间隔，规避 2203002（已有 VPN） */
const CREATE_RETRY_DELAY_MS = 400;
/** 全量重建成功后冷却，避免电梯口反复 destroy/create */
const NET_RECONNECT_COOLDOWN_MS = 12000;
/** 心跳：约每 30s 写共享文件 + 打日志（主进程 stale 判定 150s） */
const NET_HEARTBEAT_EVERY_POLLS = 12;
/** 防抖封顶：蜂窝高频事件反复 reset 时，定时器已等待超此值则必须放行 */
const NET_DEBOUNCE_MAX_HOLD_MS = 8000;

interface PhysicalLink {
  ip: string;
  iface: string;
}

export default class ProxyVpnAbility extends VpnExtensionAbility {
  private vpnConnection: vpnExtension.VpnConnection | undefined;
  /** generateVpnId() 得到的会话 id，销毁时优先按 id 销毁（API 20+ / 鸿蒙 7） */
  private vpnSessionId: string = '';
  private profile: ServerProfile | null = null;
  private smartRouteWanted: boolean = true;
  private assetPath: string = '';
  private useSmart: boolean = false;
  private currentSendThrough: string = '';
  private currentIface: string = '';
  private currentTunFd: number = -1;
  /** buildVpnConfig 解析出的节点 IPv4，供 Xray outbound 直拨，绕过 DoH 鸡生蛋 */
  private nodeDialIp: string = '';
  private sessionActive: boolean = false;
  /** 用户意图：扩展存活期间应保持隧道（重建失败后仍继续轮询） */
  private wantSession: boolean = false;
  private reconnecting: boolean = false;
  private reconnectTimer: number = -1;
  private reconnectTimerSince: number = 0;
  private pollTimer: number = -1;
  private pollTicks: number = 0;
  private lastFullRecreateAt: number = 0;
  /** 最近一次 startTunSession 失败的类别：tun / xray */
  private startFailReason: string = '';
  private netWatcher: connection.NetConnection | undefined;

  private logPumpTimer: number = -1;
  private errChars: number = 0;
  private accessChars: number = 0;
  private logRotateTimer: number = -1;

  async onCreate(want: Want): Promise<void> {
    Logger.init(this.context as common.Context);
    Logger.info(TAG, 'onCreate: starting TUN mode (net-reconnect=v3.3-hbfile+debounce-cap)');
    this.rotateXrayLogsIfNeeded(true);
    this.startXrayLogRotateWatch();

    await serverStore.init(this.context as common.Context);

    // 1) Want.parameters（部分机型可能丢大字段） 2) Preferences 跨进程兜底
    const profileJson = want.parameters?.['profileJson'] as string;
    if (profileJson) {
      try {
        this.profile = JSON.parse(profileJson) as ServerProfile;
        Logger.info(TAG, 'onCreate: profile from want.parameters');
      } catch (e) {
        Logger.error(TAG, `onCreate: parse profileJson failed: ${Logger.stringifyError(e as Error)}`);
      }
    }
    if (!this.profile) {
      this.profile = await serverStore.getPendingProfile();
      if (this.profile) {
        Logger.info(TAG, `onCreate: profile from Preferences id=${this.profile.id}`);
      }
    }
    if (!this.profile) {
      const profileId = want.parameters?.['profileId'] as string;
      if (profileId) {
        this.profile = await serverStore.getServerById(profileId);
        Logger.info(TAG, `onCreate: profile from store by id=${profileId}`);
      }
    }
    if (!this.profile) {
      Logger.error(TAG, 'onCreate: no profile from want / Preferences / id');
      serverStore.markVpnStartFailed('no-profile');
      return;
    }

    const smartRouteParam = want.parameters?.['smartRoute'];
    if (smartRouteParam === undefined) {
      this.smartRouteWanted = await serverStore.getPendingSmartRoute();
    } else {
      this.smartRouteWanted = smartRouteParam === true || smartRouteParam === 'true';
    }
    Logger.info(TAG, `onCreate: smartRoute=${this.smartRouteWanted} remark=${this.profile.remark}`);

    if (this.smartRouteWanted) {
      this.assetPath = await GeoAssetHelper.prepare(this.context as common.Context);
      if (!this.assetPath) {
        Logger.error(TAG, 'onCreate: geo assets missing, fallback to global proxy routing');
      }
    } else {
      this.assetPath = '';
    }
    this.useSmart = this.smartRouteWanted && this.assetPath.length > 0;

    this.wantSession = true;
    const ok = await this.startTunSession('initial');
    if (ok) {
      this.registerNetWatcher();
      this.startNetPoll();
    } else {
      this.wantSession = false;
      serverStore.markVpnStartFailed(this.startFailReason || 'tun');
      await serverStore.setVpnConnected(false);
    }
  }

  async onDestroy(): Promise<void> {
    Logger.info(TAG, 'onDestroy');
    this.wantSession = false;
    this.clearReconnectTimer();
    this.stopNetPoll();
    this.unregisterNetWatcher();
    this.stopXrayLogPump();
    this.stopXrayLogRotateWatch();
    this.sessionActive = false;
    this.currentTunFd = -1;
    xrayBridge.stop();
    await this.destroyConnection();
    try {
      await serverStore.setVpnConnected(false);
    } catch (_e) {
      // ignore
    }
  }

  /**
   * 建立 TUN + Xray（initial / 切网全量重建）。
   */
  private async startTunSession(reason: string): Promise<boolean> {
    if (!this.profile) {
      Logger.error(TAG, `startTunSession(${reason}): no profile`);
      return false;
    }
    const profile = this.profile;
    this.startFailReason = 'tun';

    const link = await this.resolvePhysicalLink();
    const sendThrough = link.ip;
    Logger.info(TAG,
      `startTunSession(${reason}): sendThrough=${sendThrough || '(none)'} iface=${link.iface || '(none)'}`);

    let tunFd = -1;
    let conn: vpnExtension.VpnConnection;
    try {
      conn = vpnExtension.createVpnConnection(this.context as common.VpnExtensionContext);
      this.vpnConnection = conn;
      // 文档建议：先保护进程，再建隧道，避免 Go 出站 socket 被抓回 TUN（API 22+）
      try {
        await conn.protectProcessNet();
        Logger.info(TAG, `startTunSession(${reason}): protectProcessNet(pre-create) ok`);
      } catch (e0) {
        Logger.warn(TAG, `protectProcessNet(pre-create): ${Logger.stringifyError(e0 as Error)}`);
      }
      // 优先不带 vpnId（旧式单 VPN 对象）：NetworkVpnManager.GetVpnConfigToAnco 只认 vpnObj_，
      // 带 vpnId 走多 VPN 通道时卓易通/出境易容器拿不到宿主 VPN，容器流量会绕过 TUN。
      this.vpnSessionId = '';
      try {
        const legacyConfig = await this.buildVpnConfig(profile, '');
        tunFd = await conn.create(legacyConfig);
        Logger.info(TAG, `startTunSession(${reason}): legacy create ok (anco-compatible)`);
      } catch (eLegacy) {
        Logger.warn(TAG, `legacy create failed, fallback vpnId: ${Logger.stringifyError(eLegacy as Error)}`);
        try {
          this.vpnSessionId = await conn.generateVpnId();
          Logger.info(TAG, `startTunSession(${reason}): vpnId len=${this.vpnSessionId.length}`);
        } catch (eId) {
          this.vpnSessionId = '';
          Logger.warn(TAG, `generateVpnId: ${Logger.stringifyError(eId as Error)}`);
        }
        const config = await this.buildVpnConfig(profile, this.vpnSessionId);
        tunFd = await conn.create(config);
      }
      Logger.info(TAG, `startTunSession(${reason}): tunFd=${tunFd} vpnId=${this.vpnSessionId.length > 0}`);
    } catch (e) {
      Logger.error(TAG, `startTunSession(${reason}): createVpn failed: ${Logger.stringifyError(e as Error)}`);
      await this.destroyConnection();
      this.sessionActive = false;
      this.currentTunFd = -1;
      return false;
    }

    if (tunFd <= 0) {
      Logger.error(TAG, `startTunSession(${reason}): invalid tunFd`);
      await this.destroyConnection();
      this.sessionActive = false;
      this.currentTunFd = -1;
      return false;
    }

    try {
      await conn.protectProcessNet();
      Logger.info(TAG, `startTunSession(${reason}): protectProcessNet ok`);
    } catch (e) {
      Logger.error(TAG, `startTunSession(${reason}): protectProcessNet failed: ${Logger.stringifyError(e as Error)}`);
    }

    if (!this.startXrayWith(tunFd, sendThrough, reason)) {
      this.startFailReason = 'xray';
      xrayBridge.stop();
      await this.destroyConnection();
      this.sessionActive = false;
      this.currentTunFd = -1;
      return false;
    }

    this.currentTunFd = tunFd;
    this.currentSendThrough = sendThrough;
    this.currentIface = link.iface;
    this.sessionActive = true;
    Logger.info(TAG, `startTunSession(${reason}): OK tunFd=${tunFd} sendThrough=${sendThrough || '(none)'}`);
    this.startXrayLogPump();
    try {
      await serverStore.setVpnConnected(true);
      await serverStore.touchVpnHeartbeat(sendThrough);
    } catch (_e) {
      // ignore
    }
    return true;
  }

  private startXrayWith(tunFd: number, sendThrough: string, reason: string): boolean {
    if (!this.profile) {
      return false;
    }
    // 鸿蒙 7：已用 protectProcessNet 让扩展进程走物理网；再写 sendThrough 绑 wlan IP
    // 时出站常建连失败（服务器上看不到 :4436 连接，手机却显示已连接）。不再传 sendThrough。
    const xrayConfig = buildXrayConfig(this.profile, {
      mode: 'tun',
      tunFd: tunFd,
      logDir: this.context.filesDir,
      sendThrough: '',
      smartRoute: this.useSmart,
      proxyDialAddress: this.nodeDialIp,
    });
    Logger.info(TAG,
      `startXray(${reason}): configLen=${xrayConfig.length} physIp=${sendThrough || '(none)'} dialIp=${this.nodeDialIp || '(host)'} (no sendThrough)`);
    const ok = xrayBridge.start(xrayConfig, tunFd, this.assetPath);
    if (!ok) {
      Logger.error(TAG, `startXray(${reason}): xrayBridge.start failed`);
    }
    return ok;
  }

  /**
   * 切网 / 会话异常：一律 destroy + create（与手动关开同路径）。
   * 鸿蒙无 Android setUnderlyingNetworks，软重启保留旧 TUN 已被实机证伪。
   */
  private async reconnectForNetworkChange(trigger: string): Promise<void> {
    if (!this.profile || this.reconnecting || !this.wantSession) {
      return;
    }
    this.reconnecting = true;
    try {
      const link = await this.resolvePhysicalLink();
      const nextIp = link.ip;
      const nextIface = link.iface;
      const xrayOk = xrayBridge.isRunning();
      const healthy = this.sessionActive && xrayOk && this.currentTunFd > 0 && !!this.vpnConnection;

      if (!nextIp) {
        Logger.info(TAG,
          `reconnect(${trigger}): no physical IPv4 yet (prev=${this.currentSendThrough || '(none)'}, ` +
          `session=${this.sessionActive}, xray=${xrayOk}), wait`);
        return;
      }

      const ipSame = nextIp === this.currentSendThrough;
      const ifaceSame = !nextIface || !this.currentIface || nextIface === this.currentIface;
      if (healthy && ipSame && ifaceSame) {
        return;
      }

      const sinceLast = Date.now() - this.lastFullRecreateAt;
      if (healthy && this.lastFullRecreateAt > 0 && sinceLast < NET_RECONNECT_COOLDOWN_MS) {
        const waitMs = NET_RECONNECT_COOLDOWN_MS - sinceLast + 200;
        Logger.info(TAG,
          `reconnect(${trigger}): cooldown ${sinceLast}ms < ${NET_RECONNECT_COOLDOWN_MS}ms, defer ${waitMs}ms ` +
          `(${this.currentSendThrough}@${this.currentIface || '?'} -> ${nextIp}@${nextIface || '?'})`);
        this.scheduleReconnectCheckDelayed('cool-' + trigger, waitMs, true);
        return;
      }

      Logger.info(TAG,
        `reconnect(${trigger}): full recreate ` +
        `${this.currentSendThrough || '(none)'}@${this.currentIface || '?'} -> ${nextIp}@${nextIface || '?'} ` +
        `healthy=${healthy} xray=${xrayOk}`);

      this.stopXrayLogPump();
      xrayBridge.stop();
      await this.destroyConnection();
      this.sessionActive = false;
      this.currentTunFd = -1;
      await this.delay(CREATE_RETRY_DELAY_MS);

      let ok = await this.startTunSession(`full-${trigger}`);
      if (!ok) {
        Logger.warn(TAG, `reconnect(${trigger}): first full failed, retry once`);
        await this.destroyConnection();
        await this.delay(CREATE_RETRY_DELAY_MS);
        ok = await this.startTunSession(`full-${trigger}-retry`);
      }
      if (ok) {
        this.lastFullRecreateAt = Date.now();
      } else {
        Logger.error(TAG, `reconnect(${trigger}): full recreate failed`);
        try {
          await serverStore.setVpnConnected(false);
        } catch (_e) {
          // ignore
        }
      }
    } catch (e) {
      Logger.error(TAG, `reconnect(${trigger}) failed: ${Logger.stringifyError(e as Error)}`);
    } finally {
      this.reconnecting = false;
    }
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /** 订阅网络事件（无 bearer 过滤，避免 AND 条件过严漏回调）。 */
  private registerNetWatcher(): void {
    this.unregisterNetWatcher();
    try {
      // 不传 NetSpecifier：关注默认网络变化，切 WiFi/蜂窝更稳
      const watcher = connection.createNetConnection();
      this.netWatcher = watcher;

      const schedule = (ev: string): void => {
        Logger.info(TAG, `netWatcher: ${ev}`);
        // 事件用「最后一次后稳定」防抖；轮询侧不重置，避免永远不触发
        this.scheduleReconnectCheckDelayed(`evt-${ev}`, NET_RECONNECT_DEBOUNCE_MS, true);
      };

      watcher.on('netAvailable', (_data: connection.NetHandle) => {
        schedule('netAvailable');
      });
      watcher.on('netLost', (_data: connection.NetHandle) => {
        schedule('netLost');
      });
      // netCapabilitiesChange 在电梯口极吵，不单独触发重建（靠 poll + properties）
      watcher.on('netConnectionPropertiesChange', (_data: object) => {
        schedule('netConnectionPropertiesChange');
      });
      watcher.register((err: BusinessError) => {
        if (err) {
          Logger.error(TAG, `netWatcher register failed: code=${err.code} msg=${err.message}`);
        } else {
          Logger.info(TAG, 'netWatcher registered (default net, no caps spam)');
        }
      });
    } catch (e) {
      Logger.error(TAG, `registerNetWatcher failed: ${Logger.stringifyError(e as Error)}`);
    }
  }

  private unregisterNetWatcher(): void {
    if (!this.netWatcher) {
      return;
    }
    try {
      this.netWatcher.unregister((_err: BusinessError) => {});
    } catch (_e) {
      // ignore
    }
    this.netWatcher = undefined;
  }

  /** 轮询物理链路；事件丢失或会话异常时触发全量重建。 */
  private startNetPoll(): void {
    this.stopNetPoll();
    this.pollTicks = 0;
    this.pollTimer = setInterval(() => {
      if (!this.wantSession || this.reconnecting) {
        return;
      }
      this.pollTicks++;
      this.resolvePhysicalLink().then((link: PhysicalLink) => {
        const ip = link.ip;
        const xrayOk = xrayBridge.isRunning();
        const healthy = this.sessionActive && xrayOk && this.currentTunFd > 0;

        if (this.pollTicks % NET_HEARTBEAT_EVERY_POLLS === 0) {
          Logger.info(TAG,
            `netPoll heartbeat ip=${ip || '(none)'} iface=${link.iface || '(none)'} ` +
            `bound=${this.currentSendThrough || '(none)'} session=${this.sessionActive} xray=${xrayOk}`);
          // 绑定 IP 已落后时不刷新心跳，让主进程 heal 能兜底
          if (healthy && ip && ip === this.currentSendThrough) {
            serverStore.touchVpnHeartbeat(ip).catch((_e: Error) => {
              // ignore
            });
          }
        }

        if (!ip) {
          if (this.currentSendThrough) {
            Logger.info(TAG, `netPoll: physical IPv4 empty (was ${this.currentSendThrough})`);
          }
          return;
        }

        const ipChanged = ip !== this.currentSendThrough;
        const ifaceChanged = !!link.iface && !!this.currentIface && link.iface !== this.currentIface;
        if (!healthy || ipChanged || ifaceChanged) {
          if (ipChanged) {
            Logger.info(TAG, `netPoll: IP changed ${this.currentSendThrough || '(none)'} -> ${ip}`);
          } else if (ifaceChanged) {
            Logger.info(TAG, `netPoll: iface changed ${this.currentIface} -> ${link.iface}`);
          } else {
            Logger.info(TAG, `netPoll: session unhealthy session=${this.sessionActive} xray=${xrayOk}`);
          }
          this.scheduleReconnectCheck('poll');
        }
      }).catch((e: Error) => {
        Logger.warn(TAG, `netPoll resolve failed: ${e.message}`);
      });
    }, NET_POLL_INTERVAL_MS);
    Logger.info(TAG, `netPoll started interval=${NET_POLL_INTERVAL_MS}ms`);
  }

  private stopNetPoll(): void {
    if (this.pollTimer !== -1) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private scheduleReconnectCheck(trigger: string): void {
    // 已有待执行定时器则不重置：轮询 2.5s < 防抖 4.5s 时若每次 reset，会永远不触发
    this.scheduleReconnectCheckDelayed(trigger, NET_RECONNECT_DEBOUNCE_MS, false);
  }

  private scheduleReconnectCheckDelayed(trigger: string, delayMs: number, resetIfPending: boolean): void {
    if (this.reconnectTimer !== -1) {
      const waited = Date.now() - this.reconnectTimerSince;
      // 事件风暴不得无限续命：已等待超封顶值时放行原定时器
      if (!resetIfPending || waited >= NET_DEBOUNCE_MAX_HOLD_MS) {
        return;
      }
    }
    this.clearReconnectTimer();
    const wait = delayMs > 0 ? delayMs : NET_RECONNECT_DEBOUNCE_MS;
    this.reconnectTimerSince = Date.now();
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      this.reconnectForNetworkChange(trigger).catch((e: Error) => {
        Logger.error(TAG, `reconnectForNetworkChange: ${e.message}`);
      });
    }, wait);
  }

  private clearReconnectTimer(): void {
    if (this.reconnectTimer !== -1) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
    this.reconnectTimerSince = 0;
  }

  private async destroyConnection(): Promise<void> {
    if (this.vpnConnection) {
      try {
        if (this.vpnSessionId.length > 0) {
          await this.vpnConnection.destroy(this.vpnSessionId);
        } else {
          await this.vpnConnection.destroy();
        }
      } catch (e) {
        Logger.error(TAG, `destroyConnection: ${Logger.stringifyError(e as Error)}`);
      }
      this.vpnConnection = undefined;
      this.vpnSessionId = '';
    }
  }

  /**
   * @param profile 当前节点（用于排除节点 IP）
   * @param vpnId generateVpnId 结果；空串表示不写 vpnId 字段
   */
  private async buildVpnConfig(profile: ServerProfile, vpnId: string = ''): Promise<VpnConfig> {
    // 鸿蒙 7 多 VPN：真实网卡名是 multitun-vpn1，不是旧的 vpn-tun。
    // 文档：interface 留空时系统绑到当前 VPN 虚拟网卡；填错名会导致路由无效、流量不进 TUN。
    const vpnIface = '';
    const routes: RouteInfo[] = [
      {
        interface: vpnIface,
        destination: { address: { address: '0.0.0.0', family: 1, port: 0 }, prefixLength: 0 },
        gateway: { address: '', family: 1, port: 0 },
        hasGateway: true,
        isDefaultRoute: true,
      },
    ];

    const pushExclude = (ip: string, prefix: number): void => {
      routes.push({
        interface: vpnIface,
        destination: { address: { address: ip, family: 1, port: 0 }, prefixLength: prefix },
        gateway: { address: '', family: 1, port: 0 },
        hasGateway: false,
        isDefaultRoute: false,
        isExcludedRoute: true,
      });
    };

    // 节点 IP 必须排除：域名节点若只写 host、不排除解析出的 IP，
    // Reality 出站会再被抓回 TUN（日志里会出现大量 to:节点IP:端口 + sniff 成 sni 域名）。
    const nodeIps = await this.resolveNodeIpv4s(profile.address);
    this.nodeDialIp = nodeIps.length > 0 ? nodeIps[0] : '';
    for (let i = 0; i < nodeIps.length; i++) {
      pushExclude(nodeIps[i], 32);
    }

    // 排除公共 DNS/DoH IP：浏览器会直连 1.1.1.1:443 / 8.8.8.8:443 做 DoH。
    // 若不排除，这些连接涌进 gVisor 并走 freedom，会迅速耗尽 fd（too many open files），
    // DoH 反而全部超时。Xray 自身 DoH 靠 protectProcessNet + 路由 direct 出物理网。
    const dnsIps: string[] = [
      '1.1.1.1', '1.0.0.1', '8.8.8.8', '8.8.4.4',
      '223.5.5.5', '223.6.6.6', '119.29.29.29', '114.114.114.114'
    ];
    for (let i = 0; i < dnsIps.length; i++) {
      pushExclude(dnsIps[i], 32);
    }

    if (this.useSmart) {
      // 局域网段排除
      pushExclude('10.0.0.0', 8);
      pushExclude('172.16.0.0', 12);
      pushExclude('192.168.0.0', 16);
      pushExclude('127.0.0.0', 8);
      pushExclude('169.254.0.0', 16);

      // 国内 IPv4 全量网段系统层直连（API 23+ 上限 10000；当前约 6k）
      const cnList = await CnRouteHelper.load(this.context as common.Context);
      const n = cnList.length;
      for (let i = 0; i < n; i++) {
        pushExclude(cnList[i].address, cnList[i].prefixLength);
      }
      Logger.info(TAG,
        `buildVpnConfig: smart excludes node=${nodeIps.length} dns=${dnsIps.length} cn=${n} totalRoutes=${routes.length}`);
    } else {
      Logger.info(TAG,
        `buildVpnConfig: global proxy, nodeExcludes=${nodeIps.length} dns=${dnsIps.length} routes=${routes.length}`);
    }

    // 智能分流：国内 DNS 兜底 + 公共 DNS；全局代理用公共 DNS
    const dnsServers = this.useSmart ? ['223.5.5.5', '223.6.6.6', '1.1.1.1'] : ['1.1.1.1', '8.8.8.8'];

    // 注意：不要同时设置 trustedApplications / blockedApplications。
    // 鸿蒙 7 上若传 trustedApplications:[]，可能被当成「白名单为空 → 无 App 走 VPN」。
    // 本进程已用 protectProcessNet 绕过 TUN；主界面拉订阅若仍超时，先断开 VPN 再拉。
    const config: VpnConfig = {
      addresses: [
        { address: { address: TUN_IPV4, family: 1 }, prefixLength: TUN_IPV4_PREFIX },
      ],
      routes: routes,
      mtu: MTU,
      dnsAddresses: dnsServers,
      isIPv4Accepted: true
    };
    if (vpnId.length > 0) {
      config.vpnId = vpnId;
    }
    return config;
  }

  private isIPv4Literal(host: string): boolean {
    const parts = host.split('.');
    if (parts.length !== 4) {
      return false;
    }
    for (let i = 0; i < parts.length; i++) {
      const n = Number(parts[i]);
      if (!Number.isInteger(n) || n < 0 || n > 255) {
        return false;
      }
    }
    return true;
  }

  /**
   * 解析节点地址为 IPv4，供 isExcludedRoute 使用（不把 UUID/完整 URL 写入日志）。
   * @param host 节点 address 字段（域名或字面量 IP）
   * @returns IPv4 列表
   */
  private async resolveNodeIpv4s(host: string): Promise<string[]> {
    const name = (host ?? '').trim();
    if (!name) {
      return [];
    }
    if (this.isIPv4Literal(name)) {
      return [name];
    }
    try {
      const addrs = await connection.getAddressesByName(name);
      const out: string[] = [];
      for (let i = 0; i < addrs.length; i++) {
        const ip = addrs[i]?.address ?? '';
        if (this.isIPv4Literal(ip) && out.indexOf(ip) < 0) {
          out.push(ip);
        }
      }
      Logger.info(TAG, `resolveNodeIpv4s: hostLen=${name.length} ipv4=${out.length}`);
      return out;
    } catch (e) {
      Logger.warn(TAG, `resolveNodeIpv4s failed: ${Logger.stringifyError(e as Error)}`);
      return [];
    }
  }

  /**
   * 解析物理网卡 IPv4 + iface（排除 VPN/TUN）。
   * 优先要求 INTERNET；公司网等可能暂时无 INTERNET 标记时再放宽。
   */
  private async resolvePhysicalLink(): Promise<PhysicalLink> {
    const empty: PhysicalLink = { ip: '', iface: '' };
    try {
      const nets = await connection.getAllNets();
      const strict = await this.pickPhysicalFromNets(nets, true);
      if (strict.ip) {
        return strict;
      }
      const loose = await this.pickPhysicalFromNets(nets, false);
      if (loose.ip) {
        Logger.info(TAG, `resolvePhysicalLink: loose match ${loose.ip}@${loose.iface}`);
        return loose;
      }
    } catch (e) {
      Logger.error(TAG, `resolvePhysicalLink getAllNets: ${Logger.stringifyError(e as Error)}`);
    }

    try {
      const handle = connection.getDefaultNetSync();
      const one = await this.linkFromHandle(handle);
      if (one.ip && one.ip !== TUN_IPV4) {
        return one;
      }
    } catch (e) {
      Logger.error(TAG, `resolvePhysicalLink default failed: ${Logger.stringifyError(e as Error)}`);
    }
    return empty;
  }

  private async pickPhysicalFromNets(nets: connection.NetHandle[], requireInternet: boolean): Promise<PhysicalLink> {
    for (let i = 0; i < nets.length; i++) {
      const handle = nets[i];
      try {
        const caps = await connection.getNetCapabilities(handle);
        const networkCap = caps.networkCap ? Array.from(caps.networkCap) : [];
        const bearers = caps.bearerTypes ? Array.from(caps.bearerTypes) : [];
        if (bearers.indexOf(connection.NetBearType.BEARER_VPN) >= 0) {
          continue;
        }
        if (networkCap.indexOf(connection.NetCap.NET_CAPABILITY_NOT_VPN) < 0) {
          continue;
        }
        if (requireInternet && networkCap.indexOf(connection.NetCap.NET_CAPABILITY_INTERNET) < 0) {
          continue;
        }
        const link = await this.linkFromHandle(handle);
        if (link.ip) {
          return link;
        }
      } catch (_e) {
        // try next
      }
    }
    return { ip: '', iface: '' };
  }

  private async linkFromHandle(handle: connection.NetHandle): Promise<PhysicalLink> {
    const props = await connection.getConnectionProperties(handle);
    const iface = props.interfaceName ?? '';
    if (iface.indexOf('vpn') >= 0 || iface.indexOf('tun') >= 0) {
      return { ip: '', iface: '' };
    }
    const addrs = props.linkAddresses;
    if (!addrs) {
      return { ip: '', iface: iface };
    }
    for (let i = 0; i < addrs.length; i++) {
      const addr = addrs[i]?.address?.address;
      if (addr && this.isIPv4Literal(addr) && !addr.startsWith('127.') && addr !== TUN_IPV4) {
        return { ip: addr, iface: iface };
      }
    }
    return { ip: '', iface: iface };
  }

  private startXrayLogPump(): void {
    this.stopXrayLogPump();
    // 会话期间持续泵 error + access，便于 hdc 拉 app.log 排查 Reality/DNS
    this.errChars = this.logFileSize('xray-error.log');
    this.accessChars = this.logFileSize('xray-access.log');
    this.logPumpTimer = setInterval(() => {
      this.pumpXrayLogFile('xray-error.log', 'err', true);
      this.pumpXrayLogFile('xray-access.log', 'access', true);
    }, LOG_PUMP_INTERVAL_MS);
    // 立刻泵一次启动阶段已写入的内容（否则 errChars 会跳过握手失败）
    this.errChars = 0;
    this.accessChars = 0;
    this.pumpXrayLogFile('xray-error.log', 'err', true);
    this.pumpXrayLogFile('xray-access.log', 'access', true);
  }

  private logFileSize(name: string): number {
    try {
      const path = `${this.context.filesDir}/${name}`;
      if (!fs.accessSync(path)) {
        return 0;
      }
      return fs.statSync(path).size;
    } catch (_e) {
      return 0;
    }
  }

  private stopXrayLogPump(): void {
    if (this.logPumpTimer !== -1) {
      clearInterval(this.logPumpTimer);
      this.logPumpTimer = -1;
    }
  }

  private startXrayLogRotateWatch(): void {
    this.stopXrayLogRotateWatch();
    this.logRotateTimer = setInterval(() => {
      this.rotateXrayLogsIfNeeded(false);
    }, 30000);
  }

  private stopXrayLogRotateWatch(): void {
    if (this.logRotateTimer !== -1) {
      clearInterval(this.logRotateTimer);
      this.logRotateTimer = -1;
    }
  }

  /**
   * 滚动截断 Xray 落盘日志，避免无限增长。
   */
  private rotateXrayLogsIfNeeded(forceCleanAccess: boolean): void {
    const names: string[] = ['xray-error.log', 'xray-access.log'];
    for (let i = 0; i < names.length; i++) {
      const path = `${this.context.filesDir}/${names[i]}`;
      try {
        if (!fs.accessSync(path)) {
          continue;
        }
        const st = fs.statSync(path);
        const isAccess = names[i].indexOf('access') >= 0;
        if (forceCleanAccess && isAccess) {
          fs.unlinkSync(path);
          Logger.info(TAG, `removed stale ${names[i]}`);
          continue;
        }
        if (st.size > XRAY_LOG_MAX_SIZE) {
          const f = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
          fs.closeSync(f);
          if (isAccess) {
            this.accessChars = 0;
          } else {
            this.errChars = 0;
          }
          Logger.info(TAG, `rotated ${names[i]} oldSize=${st.size}`);
        }
      } catch (_e) {
        // ignore
      }
    }
  }

  /**
   * 把 Xray 落盘日志增量写入 app.log（hdc 可直接拉）。
   * @param name 文件名
   * @param tag 日志标签 err / access
   * @param limitChunk 是否截断单次增量
   */
  private pumpXrayLogFile(name: string, tag: 'err' | 'access', limitChunk: boolean): void {
    try {
      const path = `${this.context.filesDir}/${name}`;
      if (!fs.accessSync(path)) {
        return;
      }
      const full: string = fs.readTextSync(path);
      let cursor = tag === 'err' ? this.errChars : this.accessChars;
      if (full.length <= cursor) {
        return;
      }
      let chunk: string = full.substring(cursor);
      if (limitChunk && chunk.length > LOG_PUMP_CHUNK_MAX) {
        chunk = chunk.substring(chunk.length - LOG_PUMP_CHUNK_MAX);
      }
      if (tag === 'err') {
        this.errChars = full.length;
      } else {
        this.accessChars = full.length;
      }
      let off = 0;
      const label = tag === 'err' ? 'xray-error' : 'xray-access';
      while (off < chunk.length) {
        const piece = chunk.substring(off, off + 1800);
        Logger.info(TAG, `[${label}] ${piece}`);
        off += 1800;
      }
    } catch (_e) {
      // ignore
    }
  }
}
