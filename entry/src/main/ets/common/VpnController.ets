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
   * 节点配置通过 want.parameters 传递给 VPN Extension 进程（API 22+ 支持）。
   * 同时写入 Preferences 作为 fallback，兼容旧系统版本。
   */
  async start(context: common.UIAbilityContext, profile: ServerProfile): Promise<void> {
    // 写入 Preferences 作为 fallback（extension 进程可跨进程读取）
    await serverStore.init(context);
    await serverStore.setPendingProfile(profile);

    const want: Want = {
      bundleName: BUNDLE_NAME,
      abilityName: VPN_ABILITY_NAME,
      parameters: {
        profileJson: JSON.stringify(profile),
      }
    };
    try {
      await vpnExtension.startVpnExtensionAbility(want);
      Logger.info(TAG, `requested VPN start for profile ${profile.remark}`);
    } catch (e) {
      Logger.error(TAG, `startVpnExtensionAbility failed: ${Logger.stringifyError(e as Error)}`);
      throw e as Error;
    }
  }

  async stop(context: common.UIAbilityContext): Promise<void> {
    const want: Want = {
      bundleName: BUNDLE_NAME,
      abilityName: VPN_ABILITY_NAME
    };
    try {
      await vpnExtension.stopVpnExtensionAbility(want);
      Logger.info(TAG, 'requested VPN stop');
    } catch (e) {
      Logger.error(TAG, `stopVpnExtensionAbility failed: ${Logger.stringifyError(e as Error)}`);
      throw e as Error;
    }
  }
}

export const vpnController = new VpnController();
