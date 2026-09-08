import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Logger } from '../common/Logger';
import { xrayBridge } from '../bridge/XrayBridge';
import { GeoAssetHelper } from '../common/GeoAssetHelper';
import { CnRouteHelper } from '../common/CnRouteHelper';

const TAG = 'EntryAbility';
const DOMAIN = 0x0001;

export default class EntryAbility extends UIAbility {
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
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
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
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'onBackground');
  }
}
