import xraybridge from 'libxraybridge.so';
import { Logger } from '../common/Logger';

const TAG = 'XrayBridge';

export interface TrafficStats {
  uplink: number;
  downlink: number;
}

export class XrayBridge {
  start(configJson: string, tunFd: number): boolean {
    try {
      const err = xraybridge.start(configJson, tunFd);
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
