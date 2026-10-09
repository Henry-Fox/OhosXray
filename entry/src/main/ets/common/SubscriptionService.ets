import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { parseSubscriptionPayload, SubscriptionParseResult } from '../model/SubscriptionParser';
import {
  validateSubscriptionUrl,
  SubscriptionError,
  SUBSCRIPTION_MAX_BYTES,
  SUBSCRIPTION_CONNECT_TIMEOUT_MS,
  SUBSCRIPTION_READ_TIMEOUT_MS,
  SUBSCRIPTION_MAX_REDIRECTS,
  SUBSCRIPTION_ERROR_TIMEOUT,
  SUBSCRIPTION_ERROR_HTTP_STATUS,
  SUBSCRIPTION_ERROR_OVERSIZED,
  SUBSCRIPTION_ERROR_REDIRECTS,
  SUBSCRIPTION_ERROR_DECODE,
  SUBSCRIPTION_ERROR_NETWORK
} from '../model/ImportInput';
import { Logger } from './Logger';

const TAG = 'SubscriptionService';

/** NetStack 错误码 = 2300000 + libcurl 错误码 */
const NET_CODE_TIMEOUT = 2300028;
const NET_CODE_TOO_MANY_REDIRECTS = 2300047;
const NET_CODE_FILESIZE_EXCEEDED = 2300063;

/**
 * @param code NetStack 错误码
 * @returns 对应的订阅错误类别
 */
function categoryOfNetCode(code: number): string {
  switch (code) {
    case NET_CODE_TIMEOUT:
      return SUBSCRIPTION_ERROR_TIMEOUT;
    case NET_CODE_TOO_MANY_REDIRECTS:
      return SUBSCRIPTION_ERROR_REDIRECTS;
    case NET_CODE_FILESIZE_EXCEEDED:
      return SUBSCRIPTION_ERROR_OVERSIZED;
    default:
      return SUBSCRIPTION_ERROR_NETWORK;
  }
}

/**
 * 订阅拉取服务：仅在用户主动操作时调用，不持久化订阅地址，日志只记录错误类别与状态码。
 */
export class SubscriptionService {
  /**
   * 拉取并解析订阅。
   * @param urlText 订阅地址（http/https）
   * @param vpnActive 主界面认为 VPN 已连接时为 true，缩短超时避免长时间卡在「获取中」
   * @returns 解析结果
   * @throws Error 类别见 SUBSCRIPTION_ERROR_*，可用 describeSubscriptionError 转为提示文案
   */
  static async fetch(urlText: string, vpnActive: boolean = false): Promise<SubscriptionParseResult> {
    const target = validateSubscriptionUrl(urlText);
    const connectTimeout = vpnActive ? 8000 : SUBSCRIPTION_CONNECT_TIMEOUT_MS;
    const readTimeout = vpnActive ? 12000 : SUBSCRIPTION_READ_TIMEOUT_MS;
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      usingCache: false,
      connectTimeout: connectTimeout,
      readTimeout: readTimeout,
      maxLimit: SUBSCRIPTION_MAX_BYTES
    };
    if (deviceInfo.sdkApiVersion >= 23) {
      options.maxRedirects = SUBSCRIPTION_MAX_REDIRECTS;
    }

    const request = http.createHttp();
    try {
      let response: http.HttpResponse;
      try {
        response = await request.request(target, options);
      } catch (e) {
        const code = (e as BusinessError).code;
        const category = categoryOfNetCode(code);
        Logger.warn(TAG, `fetch failed: category=${category} code=${code}`);
        throw new SubscriptionError(category);
      }

      const status = response.responseCode;
      if (status < 200 || status >= 300) {
        Logger.warn(TAG, `fetch failed: category=${SUBSCRIPTION_ERROR_HTTP_STATUS} status=${status}`);
        throw new SubscriptionError(SUBSCRIPTION_ERROR_HTTP_STATUS, status);
      }

      const body = response.result as ArrayBuffer;
      if (body.byteLength >= SUBSCRIPTION_MAX_BYTES) {
        Logger.warn(TAG, `fetch failed: category=${SUBSCRIPTION_ERROR_OVERSIZED} bytes=${body.byteLength}`);
        throw new SubscriptionError(SUBSCRIPTION_ERROR_OVERSIZED);
      }

      let text: string;
      try {
        text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(body));
      } catch (_e) {
        Logger.warn(TAG, `fetch failed: category=${SUBSCRIPTION_ERROR_DECODE}`);
        throw new SubscriptionError(SUBSCRIPTION_ERROR_DECODE);
      }

      const result = parseSubscriptionPayload(text);
      Logger.info(TAG, `fetched: nodes=${result.profiles.length} invalid=${result.invalidCount} dup=${result.duplicateCount}`);
      return result;
    } finally {
      request.destroy();
    }
  }
}
