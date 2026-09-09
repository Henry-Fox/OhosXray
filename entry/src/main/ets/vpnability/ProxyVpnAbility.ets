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
  addresses: AddressWithPrefix[];
  routes: RouteInfo[];
  mtu: number;
  dnsAddresses: string[];
  isIPv4Accepted: boolean;
  trustedApplications: string[];
  blockedApplications: string[];
}

const TUN_IPV4 = '172.19.0.1';
const TUN_IPV4_PREFIX = 30;
const MTU = 1500;

const LOG_PUMP_INTERVAL_MS = 2000;
/** 仅短窗泵 error（不再泵 access，避免撑爆 app.log） */
const LOG_PUMP_TICKS = 30; // ~1 分钟
/** Xray error 日志滚动上限 */
const XRAY_LOG_MAX_SIZE = 1024 * 1024; // 1MB

/** 事件 debounce */
const NET_RECONNECT_DEBOUNCE_MS = 1500;
/** 轮询兜底：部分机型 NetConnection 在 VPN 下不回调 */
const NET_POLL_INTERVAL_MS = 2500;

export default class ProxyVpnAbility extends VpnExtensionAbility {
  private vpnConnection: vpnExtension.VpnConnection | undefined;
  private profile: ServerProfile | null = null;
  private smartRouteWanted: boolean = true;
  private assetPath: string = '';
  private useSmart: boolean = false;
  private currentSendThrough: string = '';
  private currentTunFd: number = -1;
  private sessionActive: boolean = false;
  private reconnecting: boolean = false;
  private reconnectTimer: number = -1;
  private pollTimer: number = -1;
  private netWatcher: connection.NetConnection | undefined;

  private logPumpTimer: number = -1;
  private errChars: number = 0;
  private logRotateTimer: number = -1;

  async onCreate(want: Want): Promise<void> {
    Logger.init(this.context as common.Context);
    Logger.info(TAG, 'onCreate: starting TUN mode (net-reconnect=v2-soft+poll)');
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

    const ok = await this.startTunSession('initial');
    if (ok) {
      this.registerNetWatcher();
      this.startNetPoll();
    }
  }

  async onDestroy(): Promise<void> {
    Logger.info(TAG, 'onDestroy');
    this.clearReconnectTimer();
    this.stopNetPoll();
    this.unregisterNetWatcher();
    this.stopXrayLogPump();
    this.stopXrayLogRotateWatch();
    this.sessionActive = false;
    this.currentTunFd = -1;
    xrayBridge.stop();
    await this.destroyConnection();
  }

  /**
   * 建立 TUN + Xray（仅 initial / 软重启失败后的全量重建）。
   */
  private async startTunSession(reason: string): Promise<boolean> {
    if (!this.profile) {
      Logger.error(TAG, `startTunSession(${reason}): no profile`);
      return false;
    }
    const profile = this.profile;

    const sendThrough = await this.resolvePhysicalIPv4();
    Logger.info(TAG, `startTunSession(${reason}): sendThrough=${sendThrough || '(none)'}`);

    const config = await this.buildVpnConfig(profile);
    let tunFd = -1;
    let conn: vpnExtension.VpnConnection;
    try {
      conn = vpnExtension.createVpnConnection(this.context as common.VpnExtensionContext);
      this.vpnConnection = conn;
      // 文档建议：先保护进程，再建隧道，避免 Go 出站 socket 被抓回 TUN
      try {
        await conn.protectProcessNet();
        Logger.info(TAG, `startTunSession(${reason}): protectProcessNet(pre-create) ok`);
      } catch (e0) {
        Logger.warn(TAG, `protectProcessNet(pre-create): ${Logger.stringifyError(e0 as Error)}`);
      }
      tunFd = await conn.create(config);
      Logger.info(TAG, `startTunSession(${reason}): tunFd=${tunFd}`);
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
      xrayBridge.stop();
      await this.destroyConnection();
      this.sessionActive = false;
      this.currentTunFd = -1;
      return false;
    }

    this.currentTunFd = tunFd;
    this.currentSendThrough = sendThrough;
    this.sessionActive = true;
    Logger.info(TAG, `startTunSession(${reason}): OK tunFd=${tunFd} sendThrough=${sendThrough || '(none)'}`);
    this.startXrayLogPump();
    return true;
  }

  /**
   * 软重启：保留系统 TUN（AndroidTun.Close 不关 fd），只换 sendThrough 重拉 Xray。
   * 避免切网时整段 destroy VPN 带来的闪断/失败。
   */
  private async softRestartXray(nextIp: string, reason: string): Promise<boolean> {
    if (this.currentTunFd <= 0 || !this.vpnConnection) {
      Logger.error(TAG, `softRestart(${reason}): no tunFd`);
      return false;
    }
    Logger.info(TAG,
      `softRestart(${reason}): ${this.currentSendThrough || '(none)'} -> ${nextIp}, tunFd=${this.currentTunFd}`);

    this.stopXrayLogPump();
    xrayBridge.stop();

    try {
      await this.vpnConnection.protectProcessNet();
      Logger.info(TAG, `softRestart(${reason}): protectProcessNet ok`);
    } catch (e) {
      Logger.error(TAG, `softRestart(${reason}): protectProcessNet failed: ${Logger.stringifyError(e as Error)}`);
    }

    if (!this.startXrayWith(this.currentTunFd, nextIp, `soft-${reason}`)) {
      return false;
    }
    this.currentSendThrough = nextIp;
    this.sessionActive = true;
    this.startXrayLogPump();
    Logger.info(TAG, `softRestart(${reason}): OK sendThrough=${nextIp}`);
    return true;
  }

  private startXrayWith(tunFd: number, sendThrough: string, reason: string): boolean {
    if (!this.profile) {
      return false;
    }
    const xrayConfig = buildXrayConfig(this.profile, {
      mode: 'tun',
      tunFd: tunFd,
      logDir: this.context.filesDir,
      sendThrough: sendThrough,
      smartRoute: this.useSmart,
    });
    Logger.info(TAG, `startXray(${reason}): configLen=${xrayConfig.length} sendThrough=${sendThrough || '(none)'}`);
    const ok = xrayBridge.start(xrayConfig, tunFd, this.assetPath);
    if (!ok) {
      Logger.error(TAG, `startXray(${reason}): xrayBridge.start failed`);
    }
    return ok;
  }

  /**
   * 物理出口 IP 变化：优先软重启 Xray；失败再全量重建 TUN。
   */
  private async reconnectForNetworkChange(trigger: string): Promise<void> {
    if (!this.profile || this.reconnecting) {
      return;
    }
    this.reconnecting = true;
    try {
      const nextIp = await this.resolvePhysicalIPv4();
      if (!nextIp) {
        Logger.info(TAG, `reconnect(${trigger}): no physical IPv4 yet, skip`);
        return;
      }
      if (nextIp === this.currentSendThrough && this.sessionActive && xrayBridge.isRunning()) {
        return;
      }
      Logger.info(TAG,
        `reconnect(${trigger}): ${this.currentSendThrough || '(none)'} -> ${nextIp}`);

      const softOk = await this.softRestartXray(nextIp, trigger);
      if (softOk) {
        return;
      }

      Logger.warn(TAG, `reconnect(${trigger}): soft failed, full recreate`);
      xrayBridge.stop();
      await this.destroyConnection();
      this.sessionActive = false;
      this.currentTunFd = -1;
      const ok = await this.startTunSession(`full-${trigger}`);
      if (!ok) {
        Logger.error(TAG, `reconnect(${trigger}): full recreate failed`);
      }
    } catch (e) {
      Logger.error(TAG, `reconnect(${trigger}) failed: ${Logger.stringifyError(e as Error)}`);
    } finally {
      this.reconnecting = false;
    }
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
        this.scheduleReconnectCheck(`evt-${ev}`);
      };

      watcher.on('netAvailable', (_data: connection.NetHandle) => {
        schedule('netAvailable');
      });
      watcher.on('netLost', (_data: connection.NetHandle) => {
        schedule('netLost');
      });
      watcher.on('netCapabilitiesChange', (_data: object) => {
        schedule('netCapabilitiesChange');
      });
      watcher.on('netConnectionPropertiesChange', (_data: object) => {
        schedule('netConnectionPropertiesChange');
      });
      watcher.register((err: BusinessError) => {
        if (err) {
          Logger.error(TAG, `netWatcher register failed: code=${err.code} msg=${err.message}`);
        } else {
          Logger.info(TAG, 'netWatcher registered (default net)');
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

  /** 轮询物理 IP；事件丢失时仍能切网重绑 sendThrough。 */
  private startNetPoll(): void {
    this.stopNetPoll();
    this.pollTimer = setInterval(() => {
      if (!this.sessionActive || this.reconnecting) {
        return;
      }
      this.resolvePhysicalIPv4().then((ip: string) => {
        if (!ip) {
          return;
        }
        if (ip !== this.currentSendThrough) {
          Logger.info(TAG, `netPoll: IP changed ${this.currentSendThrough || '(none)'} -> ${ip}`);
          this.scheduleReconnectCheck('poll');
        }
      }).catch((_e: Error) => {
        // ignore transient
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
    this.clearReconnectTimer();
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      this.reconnectForNetworkChange(trigger).catch((e: Error) => {
        Logger.error(TAG, `reconnectForNetworkChange: ${e.message}`);
      });
    }, NET_RECONNECT_DEBOUNCE_MS);
  }

  private clearReconnectTimer(): void {
    if (this.reconnectTimer !== -1) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
  }

  private async destroyConnection(): Promise<void> {
    if (this.vpnConnection) {
      try {
        await this.vpnConnection.destroy();
      } catch (e) {
        Logger.error(TAG, `destroyConnection: ${Logger.stringifyError(e as Error)}`);
      }
      this.vpnConnection = undefined;
    }
  }

  private async buildVpnConfig(profile: ServerProfile): Promise<VpnConfig> {
    const routes: RouteInfo[] = [
      {
        interface: 'vpn-tun',
        destination: { address: { address: '0.0.0.0', family: 1 }, prefixLength: 0 },
        gateway: { address: '0.0.0.0', family: 1 },
        hasGateway: false,
        isDefaultRoute: true,
      },
    ];

    const pushExclude = (ip: string, prefix: number): void => {
      routes.push({
        interface: 'vpn-tun',
        destination: { address: { address: ip, family: 1 }, prefixLength: prefix },
        gateway: { address: '0.0.0.0', family: 1 },
        hasGateway: false,
        isDefaultRoute: false,
        isExcludedRoute: true,
      });
    };

    // 节点 IP 排除：代理出站不进 TUN
    if (this.isIPv4Literal(profile.address)) {
      pushExclude(profile.address, 32);
    }

    // DoH / 常用 DNS 排除：避免 dns-out/freedom 回环
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
      Logger.info(TAG, `buildVpnConfig: smart excludes dns=${dnsIps.length} cn=${n} totalRoutes=${routes.length}`);
    } else {
      Logger.info(TAG, `buildVpnConfig: global proxy, routes=${routes.length}`);
    }

    // 智能分流用国内 DNS，减少域名被解析到海外节点再绕代理
    const dnsServers = this.useSmart ? ['223.5.5.5', '223.6.6.6'] : ['1.1.1.1', '8.8.8.8'];

    return {
      addresses: [
        { address: { address: TUN_IPV4, family: 1 }, prefixLength: TUN_IPV4_PREFIX },
      ],
      routes: routes,
      mtu: MTU,
      dnsAddresses: dnsServers,
      isIPv4Accepted: true,
      trustedApplications: [],
      blockedApplications: [],
    };
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
   * 解析物理网卡 IPv4（排除 VPN/TUN）。
   */
  private async resolvePhysicalIPv4(): Promise<string> {
    try {
      const nets = await connection.getAllNets();
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
          if (networkCap.indexOf(connection.NetCap.NET_CAPABILITY_INTERNET) < 0) {
            continue;
          }
          const ip = await this.ipv4FromHandle(handle);
          if (ip) {
            return ip;
          }
        } catch (_e) {
          // try next
        }
      }
    } catch (e) {
      Logger.error(TAG, `resolvePhysicalIPv4 getAllNets: ${Logger.stringifyError(e as Error)}`);
    }

    try {
      const handle = connection.getDefaultNetSync();
      const ip = await this.ipv4FromHandle(handle);
      if (ip && ip !== TUN_IPV4) {
        return ip;
      }
    } catch (e) {
      Logger.error(TAG, `resolvePhysicalIPv4 default failed: ${Logger.stringifyError(e as Error)}`);
    }
    return '';
  }

  private async ipv4FromHandle(handle: connection.NetHandle): Promise<string> {
    const props = await connection.getConnectionProperties(handle);
    const iface = props.interfaceName ?? '';
    if (iface.indexOf('vpn') >= 0 || iface.indexOf('tun') >= 0) {
      return '';
    }
    const addrs = props.linkAddresses;
    if (!addrs) {
      return '';
    }
    for (let i = 0; i < addrs.length; i++) {
      const addr = addrs[i]?.address?.address;
      if (addr && this.isIPv4Literal(addr) && !addr.startsWith('127.') && addr !== TUN_IPV4) {
        return addr;
      }
    }
    return '';
  }

  private startXrayLogPump(): void {
    this.stopXrayLogPump();
    this.errChars = 0;
    let ticks = 0;
    this.logPumpTimer = setInterval(() => {
      ticks++;
      this.pumpErrorLog();
      if (ticks >= LOG_PUMP_TICKS) {
        this.stopXrayLogPump();
      }
    }, LOG_PUMP_INTERVAL_MS);
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
          if (!isAccess) {
            this.errChars = 0;
          }
          Logger.info(TAG, `rotated ${names[i]} oldSize=${st.size}`);
        }
      } catch (_e) {
        // ignore
      }
    }
  }

  private pumpErrorLog(): void {
    try {
      const path = `${this.context.filesDir}/xray-error.log`;
      if (!fs.accessSync(path)) {
        return;
      }
      const full: string = fs.readTextSync(path);
      if (full.length <= this.errChars) {
        return;
      }
      const chunk: string = full.substring(this.errChars);
      this.errChars = full.length;
      let off = 0;
      while (off < chunk.length) {
        const piece = chunk.substring(off, off + 1800);
        Logger.info(TAG, `[xray-error] ${piece}`);
        off += 1800;
      }
    } catch (_e) {
      // ignore
    }
  }
}
