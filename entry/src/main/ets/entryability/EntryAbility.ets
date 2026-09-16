import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Logger } from '../common/Logger';
import { xrayBridge } from '../bridge/XrayBridge';
import { GeoAssetHelper } from '../common/GeoAssetHelper';
import { CnRouteHelper } from '../common/CnRouteHelper';
import { serverStore } from '../common/ServerStore';
import { vpnController } from '../common/VpnController';

const TAG = 'EntryAbility';
const DOMAIN = 0x0001;
/** 扩展心跳约 30s 一次（共享文件）；超时则主进程 stop+start 拉起被系统杀掉的 :vpn */
const VPN_HEARTBEAT_STALE_MS = 150000;
/** 前台轮询心跳，不依赖用户手点 */
const VPN_HEAL_POLL_MS = 20000;
/** heal 防抖，避免网络抖动连打 stop/start */
const VPN_HEAL_COOLDOWN_MS = 15000;

export default class EntryAbility extends UIAbility {
  private healingVpn: boolean = false;
  private healTimer: number = -1;
  private lastHealAt: number = 0;
  private netWatcher: connection.NetConnection | undefined;
  private healQueued: boolean = false;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.init(this.context);
    hilog.info(DOMAIN, TAG, 'onCreate');
    const running = xrayBridge.isRunning();
    Logger.info(TAG, `diagnostic: xrayBridge.isRunning() in MAIN process returned ${running}`);
    // 启动时后台拉 Loyalsoldier geo + 全量国内 CIDR
    GeoAssetHelper.prepare(this.context).then(() => {
      GeoAssetHelper.updateInBackground(this.context);
    }).catch((e: Error) => {
      Logger.warn(TAG, `geo prepare: ${e.message}`);
    });
    CnRouteHelper.prepare(this.context).then(() => {
      CnRouteHelper.updateInBackground(this.context);
    }).catch((e: Error) => {
      Logger.warn(TAG, `cn prepare: ${e.message}`);
    });
    this.registerNetWatcher();
    this.startHealPoll();
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
    this.stopHealPoll();
    this.unregisterNetWatcher();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err && err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent succeeded');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'onForeground');
    this.startHealPoll();
    this.healVpnIfStale('foreground').catch((e: Error) => {
      Logger.warn(TAG, `healVpnIfStale: ${e.message}`);
    });
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'onBackground');
    // 保留 netWatcher + heal 轮询，尽量在后台也能发现扩展被杀
  }

  private registerNetWatcher(): void {
    this.unregisterNetWatcher();
    try {
      const watcher = connection.createNetConnection();
      this.netWatcher = watcher;
      const onEvt = (ev: string): void => {
        Logger.info(TAG, `netWatcher: ${ev}`);
        this.healVpnIfStale(`evt-${ev}`).catch((e: Error) => {
          Logger.warn(TAG, `heal on ${ev}: ${e.message}`);
        });
      };
      watcher.on('netAvailable', (_data: connection.NetHandle) => {
        onEvt('netAvailable');
      });
      watcher.on('netLost', (_data: connection.NetHandle) => {
        onEvt('netLost');
      });
      watcher.on('netConnectionPropertiesChange', (_data: object) => {
        onEvt('netConnectionPropertiesChange');
      });
      watcher.register((err: BusinessError) => {
        if (err) {
          Logger.error(TAG, `netWatcher register failed: code=${err.code} msg=${err.message}`);
        } else {
          Logger.info(TAG, 'netWatcher registered for vpn heal');
        }
      });
    } catch (e) {
      Logger.error(TAG, `registerNetWatcher failed: ${Logger.stringifyError(e as Error)}`);
    }
  }

  private unregisterNetWatcher(): void {
    if (!this.netWatcher) {
      return;
    }
    try {
      this.netWatcher.unregister((_err: BusinessError) => {});
    } catch (_e) {
      // ignore
    }
    this.netWatcher = undefined;
  }

  private startHealPoll(): void {
    if (this.healTimer !== -1) {
      return;
    }
    this.healTimer = setInterval(() => {
      this.healVpnIfStale('poll').catch((e: Error) => {
        Logger.warn(TAG, `heal poll: ${e.message}`);
      });
    }, VPN_HEAL_POLL_MS);
    Logger.info(TAG, `heal poll started interval=${VPN_HEAL_POLL_MS}ms`);
  }

  private stopHealPoll(): void {
    if (this.healTimer !== -1) {
      clearInterval(this.healTimer);
      this.healTimer = -1;
    }
  }

  /**
   * 扩展被系统杀掉 / 心跳停更：主进程 stop+start 拉回。
   * 同步占坑，避免 poll+多事件同时冲进来连打 stop/start。
   */
  private async healVpnIfStale(trigger: string): Promise<void> {
    if (this.healingVpn || this.healQueued) {
      return;
    }
    const sinceHeal = Date.now() - this.lastHealAt;
    if (this.lastHealAt > 0 && sinceHeal < VPN_HEAL_COOLDOWN_MS) {
      return;
    }

    this.healQueued = true;
    try {
      await serverStore.init(this.context);
      const want = await serverStore.getVpnConnected();
      if (!want) {
        return;
      }
      const hb = await serverStore.getVpnHeartbeatMs();
      if (hb <= 0) {
        return;
      }
      const age = Date.now() - hb;
      if (age < VPN_HEARTBEAT_STALE_MS) {
        return;
      }

      const profile = await serverStore.getPendingProfile();
      if (!profile) {
        Logger.warn(TAG, `vpn heartbeat stale age=${age}ms but no pending profile`);
        await serverStore.setVpnConnected(false);
        return;
      }
      // 二次确认：heal 准备期间扩展可能已恢复心跳（共享文件实时可见）
      const hb2 = await serverStore.getVpnHeartbeatMs();
      if (hb2 > 0 && Date.now() - hb2 < VPN_HEARTBEAT_STALE_MS) {
        Logger.info(TAG, `heal aborted: heartbeat recovered age=${Date.now() - hb2}ms`);
        return;
      }
      if (this.healingVpn) {
        return;
      }
      this.healingVpn = true;
      this.lastHealAt = Date.now();
      const smart = await serverStore.getPendingSmartRoute();
      try {
        Logger.warn(TAG, `vpn heartbeat stale age=${age}ms trigger=${trigger}, restarting extension`);
        try {
          await vpnController.stop(this.context);
        } catch (e) {
          Logger.warn(TAG, `heal stop: ${Logger.stringifyError(e as Error)}`);
        }
        await vpnController.start(this.context, profile, smart);
        Logger.info(TAG, `healVpnIfStale(${trigger}): restart requested`);
      } finally {
        this.healingVpn = false;
      }
    } finally {
      this.healQueued = false;
    }
  }
}
