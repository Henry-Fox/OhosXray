import { vpnExtension } from '@kit.NetworkKit';
import { common, Want } from '@kit.AbilityKit';
import { ServerProfile } from '../model/ServerProfile';
import { serverStore } from './ServerStore';
import { Logger } from './Logger';

const TAG = 'VpnController';
const BUNDLE_NAME = 'com.example.ohosxray';
const VPN_ABILITY_NAME = 'ProxyVpnAbility';

export class VpnController {
  /**
   * 启动全局 VPN（TUN 模式）。
   * @param smartRoute 默认 true：国内直连；false：全局走代理
   */
  async start(context: common.UIAbilityContext, profile: ServerProfile, smartRoute: boolean = true): Promise<void> {
    // Preferences 为跨进程主通道：部分机型 Want.parameters 里的 profileJson 到不了 Extension
    await serverStore.init(context);
    await serverStore.setPendingProfile(profile, smartRoute);
    // 乐观标记：扩展成功后再刷新心跳；失败由 UI/扩展回滚
    await serverStore.setVpnConnected(true);
    await serverStore.touchVpnHeartbeat('');

    const want: Want = {
      bundleName: BUNDLE_NAME,
      abilityName: VPN_ABILITY_NAME,
      parameters: {
        // 仍传一份作兼容；Extension 侧以 Preferences 兜底
        smartRoute: smartRoute,
        profileId: profile.id,
      }
    };
    try {
      await vpnExtension.startVpnExtensionAbility(want);
      Logger.info(TAG, `requested VPN start for profile ${profile.remark}, smartRoute=${smartRoute}`);
    } catch (e) {
      await serverStore.setVpnConnected(false);
      Logger.error(TAG, `startVpnExtensionAbility failed: ${Logger.stringifyError(e as Error)}`);
      throw e as Error;
    }
  }

  async stop(context: common.UIAbilityContext): Promise<void> {
    await serverStore.init(context);
    const want: Want = {
      bundleName: BUNDLE_NAME,
      abilityName: VPN_ABILITY_NAME
    };
    try {
      await vpnExtension.stopVpnExtensionAbility(want);
      await serverStore.setVpnConnected(false);
      Logger.info(TAG, 'requested VPN stop');
    } catch (e) {
      Logger.error(TAG, `stopVpnExtensionAbility failed: ${Logger.stringifyError(e as Error)}`);
      throw e as Error;
    }
  }
}

export const vpnController = new VpnController();
