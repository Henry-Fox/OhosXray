import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { parseShareLink } from '../model/LinkParser';
import { hasRealityKey } from '../model/SubscriptionParser';
import { REALITY_KEY_MISSING_TIP } from '../model/ImportInput';
import { ServerProfile } from '../model/ServerProfile';
import { serverStore } from './ServerStore';
import { Logger } from './Logger';

const TAG = 'ScanImportHelper';

export interface ScanImportResult {
  ok: boolean;
  cancelled?: boolean;
  profile?: ServerProfile;
  message?: string;
}

/**
 * 将扫码得到的分享链接解析并写入节点库。
 */
export class ScanImportHelper {
  /**
   * @param context UIAbilityContext
   * @param raw 扫码原文
   * @param editingId 编辑已有节点时传入
   */
  static async saveFromLink(context: common.UIAbilityContext, raw: string,
    editingId: string = ''): Promise<ScanImportResult> {
    const text = (raw ?? '').trim();
    if (!text) {
      return { ok: false, message: '未识别到内容' };
    }

    await serverStore.init(context);

    let profile: ServerProfile;
    try {
      profile = parseShareLink(text);
    } catch (_e) {
      return { ok: false, message: '不是有效的节点二维码：仅支持 vmess:// / vless:// 分享链接或 http(s) 订阅地址' };
    }
    if (!hasRealityKey(profile)) {
      return { ok: false, message: REALITY_KEY_MISSING_TIP };
    }

    if (editingId) {
      profile.id = editingId;
    } else if (!profile.id) {
      profile.id = util.generateRandomUUID();
    }
    profile.originalLink = text;
    await serverStore.upsertServer(profile);
    Logger.info(TAG, `saved profile id=${profile.id} remark=${profile.remark}`);
    return { ok: true, profile: profile, message: `已添加: ${profile.remark}` };
  }
}
