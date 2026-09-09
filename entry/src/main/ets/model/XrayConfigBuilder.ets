import { ServerProfile, ProxyProtocol } from './ServerProfile';

// 两种运行模式：
//   'tun'  — 全局透明代理，VpnExtensionAbility 创建 TUN，Xray tun inbound 读取 fd
//   'local' — 本地 SOCKS5+HTTP 代理，用户手动配置系统/WiFi 代理指向 127.0.0.1
export type XrayRunMode = 'tun' | 'local';

export interface XrayBuildOptions {
  mode: XrayRunMode;
  // tun 模式下使用（由 ProxyVpnAbility 传入，写入 Xray 根级 env["xray.tun.fd"]，
  // 同时 C++ 层也会 setenv 同名变量做双保险）
  tunFd?: number;
  // tun 模式下 Xray 运行日志的落盘目录（应用 filesDir），用于 hdc 拉回诊断
  logDir?: string;
  // tun 模式下绑定代理出站到 VPN 建立前的物理网卡 IPv4，防止回环
  sendThrough?: string;
  // 默认 true：国内 geosite:cn / geoip:cn 直连；false：全部走代理
  smartRoute?: boolean;
  // local 模式下使用
  socksListen?: string;
  socksPort?: number;
  httpListen?: string;
  httpPort?: number;
}

interface XrayUser {
  id: string;
  encryption?: string;
  flow?: string;
  alterId?: number;
  security?: string;
}

interface XrayWsHeaders {
  Host?: string;
}

interface XrayWsSettings {
  path: string;
  headers: XrayWsHeaders;
}

interface XrayGrpcSettings {
  serviceName: string;
}

interface XrayHttpUpgradeSettings {
  path: string;
  host: string;
}

interface XrayTlsSettings {
  serverName: string;
  allowInsecure: boolean;
  fingerprint: string;
}

interface XrayRealitySettings {
  serverName: string;
  publicKey: string;
  shortId: string;
  fingerprint: string;
}

interface XrayStreamSettings {
  network: string;
  security: string;
  wsSettings?: XrayWsSettings;
  grpcSettings?: XrayGrpcSettings;
  httpupgradeSettings?: XrayHttpUpgradeSettings;
  tlsSettings?: XrayTlsSettings;
  realitySettings?: XrayRealitySettings;
}

interface XrayVnextServer {
  address: string;
  port: number;
  users: XrayUser[];
}

interface XrayOutboundSettings {
  vnext: XrayVnextServer[];
}

interface XrayOutbound {
  tag: string;
  protocol: string;
  settings?: XrayOutboundSettings;
  streamSettings?: XrayStreamSettings;
  // 绑定出站到物理网卡 IP，避免 VPN 默认路由把代理连接再抓回 TUN
  sendThrough?: string;
}

interface XraySocksInboundSettings {
  auth: string;
  udp: boolean;
}

interface XrayTunInboundSettings {
  stack: string;
  mtu: number;
  // 自定义 OhosTun（tun_ohos.go，build tag ohos_native）直接从 inbound settings
  // 的 tunFd 字段读取系统已创建好的 TUN fd。二进制字符串扫描确认该精简
  // TunConfig 的唯一 fd 字段名就是 tunFd（官方 includeUIDs/multiqueue 等均不存在）。
  // 不传会读到零值 0（等价读 stdin），真正的 TUN fd 无人读取、vpn-tun RX 恒为 0。
  tunFd?: number;
}

interface XraySniffing {
  enabled: boolean;
  destOverride: string[];
}

interface XrayInbound {
  tag: string;
  protocol: string;
  listen?: string;
  port?: number;
  settings?: XraySocksInboundSettings | XrayTunInboundSettings;
  sniffing?: XraySniffing;
}

interface XrayRoutingRule {
  type: string;
  outboundTag: string;
  ip?: string[];
  domain?: string[];
  port?: number | string;
  network?: string;
  inboundTag?: string[];
}

interface XrayRouting {
  domainStrategy: string;
  rules: XrayRoutingRule[];
}

interface XrayLogConfig {
  loglevel: string;
  access?: string;
  error?: string;
}

interface XrayPolicySystem {
  statsOutboundUplink: boolean;
  statsOutboundDownlink: boolean;
}

interface XrayPolicyConfig {
  system: XrayPolicySystem;
}

interface XrayDnsServerObject {
  address: string;
  domains?: string[];
  expectIPs?: string[];
}

interface XrayDnsConfig {
  servers: Array<string | XrayDnsServerObject>;
  queryStrategy?: string;
}

interface XrayConfig {
  log: XrayLogConfig;
  dns?: XrayDnsConfig;
  stats: Record<string, boolean>;
  policy: XrayPolicyConfig;
  env?: Record<string, string>;
  inbounds: XrayInbound[];
  outbounds: XrayOutbound[];
  routing: XrayRouting;
}

function buildStreamSettings(profile: ServerProfile): XrayStreamSettings {
  const stream: XrayStreamSettings = {
    network: profile.network,
    security: 'none'
  };

  if (profile.network === 'ws') {
    const headers: XrayWsHeaders = {};
    if (profile.host) {
      headers.Host = profile.host;
    }
    const wsSettings: XrayWsSettings = {
      path: profile.path ?? '/',
      headers: headers
    };
    stream.wsSettings = wsSettings;
  } else if (profile.network === 'grpc') {
    const grpcSettings: XrayGrpcSettings = {
      serviceName: profile.serviceName ?? ''
    };
    stream.grpcSettings = grpcSettings;
  } else if (profile.network === 'httpupgrade') {
    const httpupgradeSettings: XrayHttpUpgradeSettings = {
      path: profile.path ?? '/',
      host: profile.host ?? ''
    };
    stream.httpupgradeSettings = httpupgradeSettings;
  }

  if (profile.tls === 'tls') {
    stream.security = 'tls';
    const tlsSettings: XrayTlsSettings = {
      serverName: profile.sni ?? profile.address,
      allowInsecure: profile.allowInsecure ?? false,
      fingerprint: profile.fingerprint ?? 'chrome'
    };
    stream.tlsSettings = tlsSettings;
  } else if (profile.tls === 'reality') {
    stream.security = 'reality';
    const realitySettings: XrayRealitySettings = {
      serverName: profile.sni ?? profile.address,
      publicKey: profile.realityPublicKey ?? '',
      shortId: profile.realityShortId ?? '',
      fingerprint: profile.fingerprint ?? 'chrome'
    };
    stream.realitySettings = realitySettings;
  }

  return stream;
}

function buildOutbound(profile: ServerProfile, sendThrough?: string): XrayOutbound {
  const user: XrayUser = { id: profile.uuid };

  if (profile.protocol === ProxyProtocol.VMESS) {
    user.alterId = profile.alterId ?? 0;
    user.security = profile.security ?? 'auto';
  } else {
    user.encryption = 'none';
    if (profile.flow) {
      user.flow = profile.flow;
    }
  }

  const server: XrayVnextServer = {
    address: profile.address,
    port: profile.port,
    users: [user]
  };

  const settings: XrayOutboundSettings = {
    vnext: [server]
  };

  const outbound: XrayOutbound = {
    tag: 'proxy',
    protocol: profile.protocol,
    settings: settings,
    streamSettings: buildStreamSettings(profile)
  };
  if (sendThrough && sendThrough.length > 0) {
    outbound.sendThrough = sendThrough;
  }

  return outbound;
}

export function buildXrayConfig(profile: ServerProfile, options: XrayBuildOptions): string {
  const sniffing: XraySniffing = {
    enabled: true,
    destOverride: ['http', 'tls', 'quic']
  };

  const inbounds: XrayInbound[] = [];

  if (options.mode === 'tun') {
    // TUN 模式：Xray 的 tun inbound 从根级 env["xray.tun.fd"] 读取已创建好的 fd
    // （Config.Build 时会先 os.Setenv，随后 OhosTun.NewTun 读取），不需要 listen/port。
    // gVisor 用户态协议栈终结 TUN 里的 TCP/UDP；MTU 必须与 VpnConfig.mtu 一致（1500）。
    const tunSettings: XrayTunInboundSettings = {
      stack: 'gvisor',
      mtu: 1500,
      // 关键：把 VpnConnection.create() 返回的 TUN fd 交给 OhosTun（settings 通道）。
      // 根级 env["xray.tun.fd"] 仍保留作为双保险。
      tunFd: options.tunFd,
    };
    inbounds.push({
      tag: 'tun-in',
      protocol: 'tun',
      settings: tunSettings,
      sniffing: sniffing
    });
  } else {
    // local 模式：SOCKS5 + HTTP 双 inbound
    const socksSettings: XraySocksInboundSettings = {
      auth: 'noauth',
      udp: true
    };
    inbounds.push({
      tag: 'socks-in',
      protocol: 'socks',
      listen: options.socksListen ?? '127.0.0.1',
      port: options.socksPort ?? 10808,
      settings: socksSettings,
      sniffing: sniffing
    });
    inbounds.push({
      tag: 'http-in',
      protocol: 'http',
      listen: options.httpListen ?? '127.0.0.1',
      port: options.httpPort ?? 10809,
      sniffing: sniffing
    });
  }

  const directOutbound: XrayOutbound = { tag: 'direct', protocol: 'freedom' };
  if (options.sendThrough && options.sendThrough.length > 0) {
    directOutbound.sendThrough = options.sendThrough;
  }
  const blockOutbound: XrayOutbound = { tag: 'block', protocol: 'blackhole' };
  const dnsOutbound: XrayOutbound = { tag: 'dns-out', protocol: 'dns' };

  const smartRoute = options.smartRoute !== false;

  // Vision 等流对 UDP 支持差：系统 DNS(UDP/53) 直走代理常失败。
  // 把 53 端口劫持到 dns outbound，改走 DoH(TCP/TLS)。
  const routingRules: XrayRoutingRule[] = [];
  if (options.mode === 'tun') {
    routingRules.push({
      type: 'field',
      port: 53,
      network: 'udp',
      outboundTag: 'dns-out'
    });
    routingRules.push({
      type: 'field',
      port: 53,
      network: 'tcp',
      outboundTag: 'dns-out'
    });
    // Vision/XTLS 拒 UDP/443（QUIC）；拦掉后浏览器回落 TCP
    routingRules.push({
      type: 'field',
      port: 443,
      network: 'udp',
      outboundTag: 'block'
    });
    if (smartRoute) {
      // 系统层已排除大部分国内 IP；此处兜底：仍进入 TUN 的国内域名/IP 走 direct
      routingRules.push({
        type: 'field',
        ip: ['geoip:private'],
        outboundTag: 'direct'
      });
      routingRules.push({
        type: 'field',
        domain: [
          'geosite:private',
          'geosite:apple-cn',
          'geosite:google-cn',
          'geosite:tld-cn',
          'geosite:cn'
        ],
        outboundTag: 'direct'
      });
      routingRules.push({
        type: 'field',
        domain: ['geosite:geolocation-!cn'],
        outboundTag: 'proxy'
      });
      routingRules.push({
        type: 'field',
        ip: ['geoip:cn'],
        outboundTag: 'direct'
      });
    }
  }

  const routing: XrayRouting = {
    domainStrategy: 'AsIs',
    rules: routingRules
  };

  const policySystem: XrayPolicySystem = {
    statsOutboundUplink: true,
    statsOutboundDownlink: true
  };

  // 日志：tun 模式开 debug 并落盘到应用 filesDir（Go 日志默认写 stderr，
  // NAPI 环境下会丢失，必须写文件才能用 hdc file pull 回读诊断）；
  // local 模式保持 info 且不落盘。
  const logConfig: XrayLogConfig = { loglevel: options.mode === 'tun' ? 'warning' : 'info' };
  if (options.mode === 'tun' && options.logDir && options.logDir.length > 0) {
    logConfig.error = `${options.logDir}/xray-error.log`;
  }

  const outbounds: XrayOutbound[] = [buildOutbound(profile, options.sendThrough)];
  if (options.mode === 'tun') {
    outbounds.push(dnsOutbound);
  }
  outbounds.push(directOutbound, blockOutbound);

  const config: XrayConfig = {
    log: logConfig,
    stats: {},
    policy: { system: policySystem },
    inbounds: inbounds,
    outbounds: outbounds,
    routing: routing
  };

  if (options.mode === 'tun') {
    // DoH 目标靠 VPN 排除路由直出；DNS 分流仅作域名归属提示
    const dnsServers: Array<string | XrayDnsServerObject> = [];
    if (smartRoute) {
      const cnDns: XrayDnsServerObject = {
        address: 'https://dns.alidns.com/dns-query',
        domains: [
          'geosite:cn',
          'geosite:apple-cn',
          'geosite:google-cn',
          'geosite:geolocation-cn',
          'geosite:china-list',
          'geosite:tld-cn'
        ]
      };
      dnsServers.push(cnDns);
    }
    dnsServers.push('https://1.1.1.1/dns-query');
    dnsServers.push('https://8.8.8.8/dns-query');
    const dnsConfig: XrayDnsConfig = {
      servers: dnsServers,
      queryStrategy: 'UseIPv4'
    };
    config.dns = dnsConfig;
  }

  // TUN 模式：通过根级 env 传递 TUN fd（libXray 官方机制）。
  // Xray 在 Config.Build 最开头把 env 逐项 os.Setenv，随后 OhosTun.NewTun
  // 通过 platform.EnvFlag("xray.tun.fd") 读到；不是写在 inbound settings.fd。
  if (options.mode === 'tun' && options.tunFd !== undefined && options.tunFd >= 0) {
    config.env = {
      'xray.tun.fd': options.tunFd.toString(),
    };
  }

  return JSON.stringify(config);
}
