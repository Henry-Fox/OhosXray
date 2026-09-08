import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Logger } from '../common/Logger';
import { xrayBridge } from '../bridge/XrayBridge';

const TAG = 'EntryAbility';
const DOMAIN = 0x0001;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.init(this.context);
    hilog.info(DOMAIN, TAG, 'onCreate');
    // Diagnostic: does the libxraybridge.so NAPI module load successfully in
    // the MAIN process at all? (extension process showed "Cannot read
    // property start of undefined" — need to know if this is process-specific
    // or the native module never loads anywhere. XrayBridge.isRunning()
    // internally try/catches and logs "isRunning native exception: ..." via
    // Logger if the module is undefined here too.)
    const running = xrayBridge.isRunning();
    Logger.info(TAG, `diagnostic: xrayBridge.isRunning() in MAIN process returned ${running}`);
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
