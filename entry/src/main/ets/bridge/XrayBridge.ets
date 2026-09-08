import xraybridge from 'libxraybridge.so';
import { Logger } from '../common/Logger';

const TAG = 'XrayBridge';

export interface TrafficStats {
  uplink: number;
  downlink: number;
}

export class XrayBridge {
  /**
   * @param configJson Xray JSON 配置
   * @param tunFd TUN fd；本地代理模式传 0
   * @param assetPath geoip.dat / geosite.dat 目录，可空
   */
  start(configJson: string, tunFd: number, assetPath: string = ''): boolean {
    try {
      const err = xraybridge.start(configJson, tunFd, assetPath);
      if (err) {
        Logger.error(TAG, `start failed: ${err}`);
        return false;
      }
      return true;
    } catch (e) {
      Logger.error(TAG, `start native exception: ${Logger.stringifyError(e)}`);
      return false;
    }
  }

  stop(): void {
    try {
      xraybridge.stop();
    } catch (e) {
      Logger.error(TAG, `stop native exception: ${Logger.stringifyError(e)}`);
    }
  }

  isRunning(): boolean {
    try {
      return xraybridge.isRunning() as boolean;
    } catch (e) {
      Logger.error(TAG, `isRunning native exception: ${Logger.stringifyError(e)}`);
      return false;
    }
  }

  queryStats(tag: string = 'proxy'): TrafficStats {
    try {
      return JSON.parse(xraybridge.queryStats(tag)) as TrafficStats;
    } catch (e) {
      Logger.error(TAG, `queryStats failed: ${Logger.stringifyError(e)}`);
      return { uplink: 0, downlink: 0 };
    }
  }
}

export const xrayBridge = new XrayBridge();
