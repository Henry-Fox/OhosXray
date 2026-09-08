/**
 * 节点（服务器）配置模型。
 * 字段命名对齐 Xray-core 的 JSON 配置（vnext/users），方便后续直接拼装成
 * Xray 的 outbound 配置块，不需要再做一次字段名转换。
 */

export enum ProxyProtocol {
  VMESS = 'vmess',
  VLESS = 'vless'
}

export interface ServerProfile {
  // 本地管理用，不参与 Xray 配置生成
  id: string;
  remark: string;
  createdAt: number;

  // 核心连接参数
  protocol: ProxyProtocol;
  address: string;
  port: number;
  uuid: string;

  // VMess 专用（VLESS 忽略）
  alterId?: number;     // legacy AEAD 关闭时使用，新版建议填 0
  security?: string;    // 'auto' | 'aes-128-gcm' | 'chacha20-poly1305' | 'none'

  // VLESS 专用（VMess 忽略）
  flow?: string;        // 例如 'xtls-rprx-vision'，留空表示不使用

  // 传输层
  network: string;      // 'tcp' | 'ws' | 'grpc' | 'httpupgrade' | 'h2'
  path?: string;         // ws / httpupgrade 路径
  host?: string;         // ws / h2 的 Host 头
  serviceName?: string;  // grpc serviceName

  // TLS / Reality
  tls: 'none' | 'tls' | 'reality';
  sni?: string;
  allowInsecure?: boolean;
  fingerprint?: string;       // uTLS fingerprint，例如 'chrome'
  realityPublicKey?: string;  // tls = 'reality' 时使用
  realityShortId?: string;

  // 原始分享链接，用于编辑节点时回显
  originalLink?: string;
}

export function createEmptyProfile(): ServerProfile {
  return {
    id: '',
    remark: '',
    createdAt: Date.now(),
    protocol: ProxyProtocol.VLESS,
    address: '',
    port: 443,
    uuid: '',
    network: 'tcp',
    tls: 'tls',
    allowInsecure: false
  };
}
