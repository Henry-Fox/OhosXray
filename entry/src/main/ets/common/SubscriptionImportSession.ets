import { ServerProfile } from '../model/ServerProfile';
import { SubscriptionParseResult } from '../model/SubscriptionParser';

/**
 * @param result 解析结果
 * @returns 深拷贝
 */
function cloneResult(result: SubscriptionParseResult): SubscriptionParseResult {
  const copy: SubscriptionParseResult = {
    profiles: result.profiles.map((p: ServerProfile) => JSON.parse(JSON.stringify(p)) as ServerProfile),
    invalidCount: result.invalidCount,
    duplicateCount: result.duplicateCount,
    missingRealityKeyCount: result.missingRealityKeyCount
  };
  return copy;
}

/**
 * 订阅预览数据的进程内一次性交接：只保存解析结果，不保存订阅地址，也不写入磁盘或路由参数。
 */
export class SubscriptionImportSession {
  private static pending: SubscriptionParseResult | null = null;

  /**
   * @param result 待预览的解析结果
   */
  static set(result: SubscriptionParseResult): void {
    SubscriptionImportSession.pending = cloneResult(result);
  }

  /**
   * 取出并清空待预览数据。
   * @returns 解析结果；没有数据时为 null
   */
  static take(): SubscriptionParseResult | null {
    const result = SubscriptionImportSession.pending;
    SubscriptionImportSession.pending = null;
    return result;
  }

  static clear(): void {
    SubscriptionImportSession.pending = null;
  }
}
