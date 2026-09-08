import { VpnExtensionAbility } from '@kit.NetworkKit';
import { vpnExtension } from '@kit.NetworkKit';
import { connection } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import { common } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';
import { Logger } from '../common/Logger';
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

// 与已端到端验证的 shadowsocks-ohos 参考实现逐字段对齐：
// 172.19.0.1/30、唯一一条 0.0.0.0/0 默认路由、MTU 1500、仅 IPv4。
const TUN_IPV4 = '172.19.0.1';
const TUN_IPV4_PREFIX = 30;
const MTU = 1500;

// Xray 自身日志文件权限是 600（仅应用 UID 可读，hdc shell 拉不到），
// 启动后由本进程把增量内容转写进 660 可读的 app.log，便于 hdc 回读诊断。
const LOG_PUMP_INTERVAL_MS = 2000;
const LOG_PUMP_TICKS = 12; // 共转写约 24 秒

export default class ProxyVpnAbility extends VpnExtensionAbility {
  private vpnConnection: vpnExtension.VpnConnection | undefined;
  private profile: ServerProfile | null = null;
  private logPumpTimer: number = -1;
  private errChars: number = 0;
  private accChars: number = 0;

  async onCreate(want: Want): Promise<void> {
    Logger.init(this.context as common.Context);
    Logger.info(TAG, 'onCreate: starting TUN mode');

    // 1. 从 want.parameters 读取节点配置（API 22+ 支持跨进程传递）
    const profileJson = want.parameters?.['profileJson'] as string;
    if (!profileJson) {
      Logger.error(TAG, 'onCreate: missing profileJson in want.parameters');
      return;
    }
    try {
      this.profile = JSON.parse(profileJson) as ServerProfile;
    } catch (e) {
      Logger.error(TAG, `onCreate: failed to parse profileJson: ${Logger.stringifyError(e as Error)}`);
      return;
    }

    // 1.5 VPN 建立前记下物理网卡 IPv4，供 Xray sendThrough 绑出口防回环
    const sendThrough = await this.resolvePhysicalIPv4();
    Logger.info(TAG, `onCreate: sendThrough=${sendThrough || '(none)'}`);

    // 2. 构建 VpnConfig（与参考实现一致：仅一条默认路由，不使用 excludeRoutes）
    const profile: ServerProfile = this.profile;
    const config = this.buildVpnConfig(profile);

    // 3. 创建 VpnConnection 并拿到 tunFd（此步同时由系统建立 TUN 接口与路由）
    let tunFd = -1;
    let conn: vpnExtension.VpnConnection;
    try {
      conn = vpnExtension.createVpnConnection(this.context as common.VpnExtensionContext);
      this.vpnConnection = conn;
      tunFd = await conn.create(config);
      Logger.info(TAG, `onCreate: tunFd=${tunFd}`);
    } catch (e) {
      Logger.error(TAG, `onCreate: createVpnConnection failed: ${Logger.stringifyError(e as Error)}`);
      await this.destroyConnection();
      return;
    }

    if (tunFd <= 0) {
      Logger.error(TAG, 'onCreate: invalid tunFd');
      await this.destroyConnection();
      return;
    }

    // 4. 让本 VPN 进程（含 native Go 核心）之后创建的所有 socket 绕过 TUN、
    //    直接走物理网卡，避免核心连代理服务器的出站流量又被默认路由抓回 TUN
    //    形成回环死锁（等价 Android VpnService.protect）。这是本实现的防环
    //    手段之一；Go socket 在部分机型上仍可能不生效，故另配 sendThrough。
    try {
      await conn.protectProcessNet();
      Logger.info(TAG, 'onCreate: protectProcessNet ok, process sockets bypass TUN');
    } catch (e) {
      Logger.error(TAG, `onCreate: protectProcessNet failed: ${Logger.stringifyError(e as Error)}`);
    }

    // 5. 构建 Xray TUN 配置并启动核心
    const xrayConfig = buildXrayConfig(profile, {
      mode: 'tun',
      tunFd: tunFd,
      logDir: this.context.filesDir,
      sendThrough: sendThrough,
    });
    Logger.info(TAG, `onCreate: xray config=${xrayConfig}`);

    const ok = xrayBridge.start(xrayConfig, tunFd);
    if (!ok) {
      Logger.error(TAG, 'onCreate: xrayBridge.start failed');
      xrayBridge.stop();
      await this.destroyConnection();
      return;
    }

    Logger.info(TAG, 'onCreate: VPN TUN mode started successfully');
    this.startXrayLogPump();
  }

  async onDestroy(): Promise<void> {
    Logger.info(TAG, 'onDestroy');
    this.stopXrayLogPump();
    xrayBridge.stop();
    await this.destroyConnection();
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

  // 与 shadowsocks-ohos 完全一致：addresses=172.19.0.1/30，routes 只有一条
  // 0.0.0.0/0 默认路由（gateway 0.0.0.0 + hasGateway:false + isDefaultRoute），
  // 另为节点 IPv4 加 isExcludedRoute，避免代理出站再被默认路由抓回 TUN。
  private buildVpnConfig(profile: ServerProfile): VpnConfig {
    const routes: RouteInfo[] = [
      {
        interface: 'vpn-tun',
        destination: { address: { address: '0.0.0.0', family: 1 }, prefixLength: 0 },
        gateway: { address: '0.0.0.0', family: 1 },
        hasGateway: false,
        isDefaultRoute: true,
      },
    ];
    if (this.isIPv4Literal(profile.address)) {
      routes.push({
        interface: 'vpn-tun',
        destination: { address: { address: profile.address, family: 1 }, prefixLength: 32 },
        gateway: { address: '0.0.0.0', family: 1 },
        hasGateway: false,
        isDefaultRoute: false,
        isExcludedRoute: true,
      });
    }
    return {
      addresses: [
        { address: { address: TUN_IPV4, family: 1 }, prefixLength: TUN_IPV4_PREFIX },
      ],
      routes: routes,
      mtu: MTU,
      dnsAddresses: ['1.1.1.1', '8.8.8.8'],
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
   * 在建立 VPN 之前读取当前默认网络的 IPv4，供 Xray sendThrough 使用。
   */
  private async resolvePhysicalIPv4(): Promise<string> {
    try {
      const handle = connection.getDefaultNetSync();
      const props = connection.getConnectionPropertiesSync(handle);
      Logger.info(TAG, `resolvePhysicalIPv4: iface=${props.interfaceName}`);
      const addrs = props.linkAddresses;
      if (!addrs) {
        return '';
      }
      for (let i = 0; i < addrs.length; i++) {
        const addr = addrs[i]?.address?.address;
        if (addr && this.isIPv4Literal(addr) && !addr.startsWith('127.')) {
          return addr;
        }
      }
    } catch (e) {
      Logger.error(TAG, `resolvePhysicalIPv4 failed: ${Logger.stringifyError(e as Error)}`);
    }
    return '';
  }

  // 把 Xray 的 error/access 日志增量转写进 app.log（shell 可读）。
  private startXrayLogPump(): void {
    this.errChars = 0;
    this.accChars = 0;
    let ticks = 0;
    this.logPumpTimer = setInterval(() => {
      ticks++;
      this.pumpFile('xray-error.log', false);
      this.pumpFile('xray-access.log', true);
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

  private pumpFile(fileName: string, isAccess: boolean): void {
    try {
      const path = `${this.context.filesDir}/${fileName}`;
      if (!fs.accessSync(path)) {
        return;
      }
      const full: string = fs.readTextSync(path);
      const start: number = isAccess ? this.accChars : this.errChars;
      if (full.length <= start) {
        return;
      }
      const chunk: string = full.substring(start);
      if (isAccess) {
        this.accChars = full.length;
      } else {
        this.errChars = full.length;
      }
      const label = isAccess ? 'xray-access' : 'xray-error';
      // 分块输出，避免单条日志过长
      let off = 0;
      while (off < chunk.length) {
        const piece = chunk.substring(off, off + 1800);
        Logger.info(TAG, `[${label}] ${piece}`);
        off += 1800;
      }
    } catch (_e) {
      // 文件尚未生成或暂时不可读，等下一个 tick 重试
    }
  }
}
