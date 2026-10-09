import { util } from '@kit.ArkTS';
import { parseShareLink } from './LinkParser';
import { ServerProfile } from './ServerProfile';

/** 订阅内容为空 */
export const SUBSCRIPTION_ERROR_EMPTY = 'empty';
/** 订阅内容中没有可用的 VMess/VLESS 节点 */
export const SUBSCRIPTION_ERROR_NO_NODES = 'no-supported-nodes';

/**
 * 订阅解析结果。
 */
export interface SubscriptionParseResult {
  /** 可导入的节点（已去重、已校验） */
  profiles: ServerProfile[];
  /** 无法解析、协议不支持或字段不完整的条目数 */
  invalidCount: number;
  /** 订阅内重复的条目数 */
  duplicateCount: number;
}

/**
 * 判断解析出的节点是否具备连接所需的最少字段。
 * @param profile 解析出的节点
 * @returns 地址、UUID 非空且端口在 1–65535 时为 true
 */
export function isUsableProfile(profile: ServerProfile): boolean {
  return (profile.address ?? '').trim().length > 0 &&
    (profile.uuid ?? '').trim().length > 0 &&
    Number.isInteger(profile.port) && profile.port >= 1 && profile.port <= 65535;
}

/**
 * 节点端点标识：协议 + UUID + 小写地址 + 端口。
 * @param profile 节点
 * @returns 用于去重和匹配的键
 */
export function endpointKey(profile: ServerProfile): string {
  return `${profile.protocol}|${profile.uuid.trim()}|${profile.address.trim().toLowerCase()}|${profile.port}`;
}

/**
 * 按行拆分并去掉空白行。
 * @param text 原始文本
 * @returns 去除首尾空白后的非空行
 */
function splitLines(text: string): string[] {
  return text.replace(/\r\n?/g, '\n').split('\n')
    .map((line: string) => line.trim())
    .filter((line: string) => line.length > 0);
}

/**
 * @param line 单行文本
 * @returns 是否为 vmess:// 或 vless:// 开头
 */
function isSupportedLine(line: string): boolean {
  return line.startsWith('vmess://') || line.startsWith('vless://');
}

/**
 * 尝试把整段内容按标准或 URL-safe Base64 解码（允许缺省 padding 与换行折行）。
 * @param text 原始文本
 * @returns 解码后的 UTF-8 文本；不像 Base64 或解码失败时返回 null
 */
function tryDecodeBase64(text: string): string | null {
  const compact = text.replace(/\s+/g, '');
  if (!/^[A-Za-z0-9+/_-]+={0,2}$/.test(compact)) {
    return null;
  }
  let normalized = compact.replace(/-/g, '+').replace(/_/g, '/').replace(/=+$/, '');
  if (normalized.length % 4 === 1) {
    return null;
  }
  while (normalized.length % 4 !== 0) {
    normalized += '=';
  }
  try {
    const bytes = new util.Base64Helper().decodeSync(normalized, util.Type.BASIC);
    return util.TextDecoder.create('utf-8').decodeToString(bytes);
  } catch (_e) {
    return null;
  }
}

/**
 * 解析订阅响应内容（纯文本或 Base64），提取可导入的 VMess/VLESS 节点。
 * 单条坏数据只计入 invalidCount，不影响其他条目。
 * @param payload 订阅响应文本
 * @returns 解析结果
 * @throws Error message 仅为错误类别（SUBSCRIPTION_ERROR_*），不包含订阅内容
 */
export function parseSubscriptionPayload(payload: string): SubscriptionParseResult {
  const raw = (payload ?? '').trim();
  if (!raw) {
    throw new Error(SUBSCRIPTION_ERROR_EMPTY);
  }

  let lines = splitLines(raw);
  const decoded = tryDecodeBase64(raw);
  if (decoded !== null) {
    const decodedLines = splitLines(decoded);
    if (decodedLines.some(isSupportedLine)) {
      lines = decodedLines;
    }
  }

  const result: SubscriptionParseResult = { profiles: [], invalidCount: 0, duplicateCount: 0 };
  const seenLinks = new Set<string>();
  const seenKeys = new Set<string>();
  for (const line of lines) {
    if (seenLinks.has(line)) {
      result.duplicateCount++;
      continue;
    }
    seenLinks.add(line);

    let profile: ServerProfile;
    try {
      profile = parseShareLink(line);
    } catch (_e) {
      result.invalidCount++;
      continue;
    }
    if (!isUsableProfile(profile)) {
      result.invalidCount++;
      continue;
    }
    const key = endpointKey(profile);
    if (seenKeys.has(key)) {
      result.duplicateCount++;
      continue;
    }
    seenKeys.add(key);
    profile.originalLink = line;
    result.profiles.push(profile);
  }

  if (result.profiles.length === 0) {
    throw new Error(SUBSCRIPTION_ERROR_NO_NODES);
  }
  return result;
}
