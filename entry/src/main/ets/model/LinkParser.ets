import { util } from '@kit.ArkTS';
import { url } from '@kit.ArkTS';
import { ServerProfile, ProxyProtocol, createEmptyProfile } from './ServerProfile';

/**
 * vmess:// 链接是 v2rayN 风格：vmess://base64(JSON)
 * JSON 字段沿用社区约定：v/ps/add/port/id/aid/scy/net/type/host/path/tls/sni 等。
 */
interface VmessLinkPayload {
  v?: string;
  ps?: string;
  add?: string;
  port?: string | number;
  id?: string;
  aid?: string | number;
  scy?: string;
  net?: string;
  type?: string;
  host?: string;
  path?: string;
  tls?: string;
  sni?: string;
  fp?: string;
}

function base64UrlDecodeToString(input: string): string {
  // vmess 链接中的 base64 常见省略 padding，这里先补齐
  let normalized = input.replace(/-/g, '+').replace(/_/g, '/');
  while (normalized.length % 4 !== 0) {
    normalized += '=';
  }
  const helper = new util.Base64Helper();
  const bytes = helper.decodeSync(normalized, util.Type.BASIC);
  const decoder = util.TextDecoder.create('utf-8');
  return decoder.decodeToString(bytes);
}

export function parseVmessLink(link: string): ServerProfile {
  if (!link.startsWith('vmess://')) {
    throw new Error('not a vmess link');
  }
  const raw = link.substring('vmess://'.length);
  const jsonText = base64UrlDecodeToString(raw);
  const payload = JSON.parse(jsonText) as VmessLinkPayload;

  const profile = createEmptyProfile();
  profile.id = util.generateRandomUUID();
  profile.protocol = ProxyProtocol.VMESS;
  profile.remark = payload.ps ?? payload.add ?? 'vmess node';
  profile.address = payload.add ?? '';
  profile.port = Number(payload.port ?? 443);
  profile.uuid = payload.id ?? '';
  profile.alterId = Number(payload.aid ?? 0);
  profile.security = payload.scy ?? 'auto';
  profile.network = payload.net ?? 'tcp';
  profile.host = payload.host;
  profile.path = payload.path;
  profile.tls = payload.tls === 'tls' ? 'tls' : 'none';
  profile.sni = payload.sni;
  profile.fingerprint = payload.fp;
  return profile;
}

/**
 * vless:// 链接格式：
 * vless://uuid@host:port?encryption=none&security=tls&sni=xxx&type=ws&path=%2Fxxx&host=xxx&flow=xxx#remark
 */
export function parseVlessLink(link: string): ServerProfile {
  if (!link.startsWith('vless://')) {
    throw new Error('not a vless link');
  }

  const parsed = new url.URL(link);
  // url.URL 会把 vless:// 当作非特殊协议解析，userinfo 在大多数实现里是 username 字段
  const uuid = decodeURIComponent(parsed.username);
  const address = parsed.hostname;
  const port = Number(parsed.port || '443');
  const params = parsed.searchParams;

  const profile = createEmptyProfile();
  profile.id = util.generateRandomUUID();
  profile.protocol = ProxyProtocol.VLESS;
  profile.remark = decodeURIComponent(parsed.hash.replace(/^#/, '')) || `${address}:${port}`;
  profile.address = address;
  profile.port = port;
  profile.uuid = uuid;
  profile.flow = params.get('flow') ?? '';
  profile.network = params.get('type') ?? 'tcp';
  profile.host = params.get('host') ?? undefined;
  profile.path = params.get('path') ? decodeURIComponent(params.get('path') as string) : undefined;
  profile.serviceName = params.get('serviceName') ?? undefined;

  const security = params.get('security') ?? 'none';
  if (security === 'reality') {
    profile.tls = 'reality';
    profile.realityPublicKey = params.get('pbk') ?? undefined;
    profile.realityShortId = params.get('sid') ?? undefined;
  } else if (security === 'tls') {
    profile.tls = 'tls';
  } else {
    profile.tls = 'none';
  }
  profile.sni = params.get('sni') ?? undefined;
  profile.fingerprint = params.get('fp') ?? undefined;
  profile.allowInsecure = params.get('allowInsecure') === '1' || params.get('allowInsecure') === 'true';
  return profile;
}

export function parseShareLink(link: string): ServerProfile {
  const trimmed = link.trim();
  if (trimmed.startsWith('vmess://')) {
    return parseVmessLink(trimmed);
  }
  if (trimmed.startsWith('vless://')) {
    return parseVlessLink(trimmed);
  }
  throw new Error('unsupported link scheme, only vmess:// and vless:// are supported');
}
