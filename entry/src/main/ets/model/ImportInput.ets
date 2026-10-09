import { SUBSCRIPTION_ERROR_EMPTY, SUBSCRIPTION_ERROR_NO_NODES, SUBSCRIPTION_ERROR_REALITY_KEY } from './SubscriptionParser';

/** 节点为 REALITY 但链接缺少公钥（pbk）时的提示 */
export const REALITY_KEY_MISSING_TIP = '链接缺少 REALITY 公钥（pbk），无法连接，请检查面板配置';

/** 订阅响应体上限（字节） */
export const SUBSCRIPTION_MAX_BYTES = 2 * 1024 * 1024;
/** 连接超时（毫秒） */
export const SUBSCRIPTION_CONNECT_TIMEOUT_MS = 12000;
/** 读取超时（毫秒） */
export const SUBSCRIPTION_READ_TIMEOUT_MS = 30000;
/** 最多跟随的重定向次数（仅 API 23+ 生效） */
export const SUBSCRIPTION_MAX_REDIRECTS = 3;

export const SUBSCRIPTION_ERROR_INVALID_URL = 'invalid-url';
export const SUBSCRIPTION_ERROR_TIMEOUT = 'timeout';
export const SUBSCRIPTION_ERROR_HTTP_STATUS = 'http-status';
export const SUBSCRIPTION_ERROR_OVERSIZED = 'oversized';
export const SUBSCRIPTION_ERROR_REDIRECTS = 'too-many-redirects';
export const SUBSCRIPTION_ERROR_DECODE = 'decode';
export const SUBSCRIPTION_ERROR_NETWORK = 'network';

/**
 * 导入输入类型：单节点分享链接 / 订阅地址 / 不支持。
 */
export type ImportInputKind = 'direct' | 'subscription' | 'unsupported';

/**
 * 订阅相关错误。message 只包含错误类别，绝不包含订阅地址或内容。
 */
export class SubscriptionError extends Error {
  /** 错误类别（SUBSCRIPTION_ERROR_*） */
  readonly category: string;
  /** HTTP 状态码，仅 http-status 类别有值 */
  readonly status: number;

  /**
   * @param category 错误类别
   * @param status HTTP 状态码
   */
  constructor(category: string, status: number = 0) {
    super(category);
    this.name = 'SubscriptionError';
    this.category = category;
    this.status = status;
  }
}

/**
 * 按协议头判断输入类型（忽略首尾空白与大小写）。
 * @param raw 扫码或粘贴的原文
 * @returns 输入类型
 */
export function classifyImportInput(raw: string): ImportInputKind {
  const lower = (raw ?? '').trim().toLowerCase();
  if (lower.startsWith('vmess://') || lower.startsWith('vless://')) {
    return 'direct';
  }
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    return 'subscription';
  }
  return 'unsupported';
}

/**
 * 校验订阅地址：仅允许 http/https，主机非空，端口合法，不含账号密码和空白字符。
 * @param urlText 订阅地址
 * @returns 去除首尾空白后的地址
 * @throws SubscriptionError 类别为 invalid-url
 */
export function validateSubscriptionUrl(urlText: string): string {
  const text = (urlText ?? '').trim();
  const match = /^https?:\/\/([^/?#]*)/i.exec(text);
  if (!match || /\s/.test(text)) {
    throw new SubscriptionError(SUBSCRIPTION_ERROR_INVALID_URL);
  }
  const authority = match[1];
  if (authority.indexOf('@') >= 0) {
    throw new SubscriptionError(SUBSCRIPTION_ERROR_INVALID_URL);
  }
  const portMatch = /:(\d*)$/.exec(authority);
  const host = portMatch ? authority.substring(0, authority.length - portMatch[0].length) : authority;
  if (!host) {
    throw new SubscriptionError(SUBSCRIPTION_ERROR_INVALID_URL);
  }
  if (portMatch && portMatch[1].length > 0) {
    const port = Number(portMatch[1]);
    if (port < 1 || port > 65535) {
      throw new SubscriptionError(SUBSCRIPTION_ERROR_INVALID_URL);
    }
  }
  return text;
}

/**
 * 把订阅流程中的错误转换为面向用户的中文提示，不回显任何地址或内容。
 * @param e 捕获到的错误
 * @returns 提示文案
 */
export function describeSubscriptionError(e: Error): string {
  const category = e instanceof SubscriptionError ? e.category : e.message;
  switch (category) {
    case SUBSCRIPTION_ERROR_INVALID_URL:
      return '订阅地址无效：仅支持 http:// 或 https://，且不能包含账号密码';
    case SUBSCRIPTION_ERROR_TIMEOUT:
      return '获取订阅超时，请检查网络后重试';
    case SUBSCRIPTION_ERROR_HTTP_STATUS: {
      const status = e instanceof SubscriptionError ? e.status : 0;
      return `订阅服务器返回错误状态（HTTP ${status}）`;
    }
    case SUBSCRIPTION_ERROR_OVERSIZED:
      return '订阅内容过大（超过 2 MB）';
    case SUBSCRIPTION_ERROR_REDIRECTS:
      return '订阅地址重定向次数过多';
    case SUBSCRIPTION_ERROR_DECODE:
      return '订阅内容不是有效的文本';
    case SUBSCRIPTION_ERROR_EMPTY:
      return '订阅内容为空';
    case SUBSCRIPTION_ERROR_NO_NODES:
      return '订阅中没有可导入的 VMess / VLESS 节点';
    case SUBSCRIPTION_ERROR_REALITY_KEY:
      return `订阅中的节点均无法导入：${REALITY_KEY_MISSING_TIP}`;
    default:
      return '获取订阅失败，请检查网络后重试';
  }
}
