import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import fs from '@ohos.file.fs';
import { Logger } from './Logger';

const TAG = 'CnRouteHelper';

/** API 23+ routes ?? 10000?????/DNS/??/??? */
const MAX_CN_ROUTES = 9800;

/** ???? 24h */
const UPDATE_INTERVAL_MS = 24 * 60 * 60 * 1000;
const CONNECT_TIMEOUT_MS = 12000;
const READ_TIMEOUT_MS = 60000;
const MIN_CN_BYTES = 20000;

export interface CidrRoute {
  address: string;
  prefixLength: number;
}

interface UpdateMeta {
  updatedAt: number;
  source: string;
  count: number;
}

/**
 * ???? IPv4 ???CIDR??? VPN isExcludedRoute ??????
 * ????Loyalsoldier/geoip ?? cn.txt??????API 23+ ????????
 * https://github.com/Loyalsoldier/geoip
 */
export class CnRouteHelper {
  private static cached: CidrRoute[] | null = null;
  private static updating: boolean = false;

  /**
   * ?? filesDir ??? cn-ipv4.txt???? rawfile ????
   */
  static async prepare(context: common.Context): Promise<string> {
    const assetDir = `${context.filesDir}/xray-asset`;
    try {
      if (!fs.accessSync(assetDir)) {
        fs.mkdirSync(assetDir);
      }
    } catch (_e) {
      try {
        fs.mkdirSync(assetDir);
      } catch (e2) {
        Logger.error(TAG, `mkdir failed: ${Logger.stringifyError(e2 as Error)}`);
        return '';
      }
    }
    const dest = `${assetDir}/cn-ipv4.txt`;
    try {
      if (fs.accessSync(dest)) {
        const st = fs.statSync(dest);
        if (st.size > MIN_CN_BYTES) {
          return dest;
        }
      }
    } catch (_e) {
      // copy
    }
    try {
      const data = await context.resourceManager.getRawFileContent('cn-ipv4.txt');
      const ab = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
      const file = fs.openSync(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, ab);
      fs.closeSync(file);
      Logger.info(TAG, `copied rawfile cn-ipv4.txt size=${data.byteLength}`);
      return dest;
    } catch (e) {
      Logger.error(TAG, `copy rawfile failed: ${Logger.stringifyError(e as Error)}`);
      return '';
    }
  }

  /**
   * ?????? cn.txt?
   */
  static updateInBackground(context: common.Context): void {
    CnRouteHelper.tryUpdate(context).catch((e: Error) => {
      Logger.warn(TAG, `bg update: ${e.message}`);
    });
  }

  static async tryUpdate(context: common.Context): Promise<boolean> {
    if (CnRouteHelper.updating) {
      return false;
    }
    CnRouteHelper.updating = true;
    try {
      const path = await CnRouteHelper.prepare(context);
      if (!path) {
        return false;
      }
      const assetDir = `${context.filesDir}/xray-asset`;
      const meta = CnRouteHelper.readMeta(assetDir);
      const now = Date.now();
      if (meta && (now - meta.updatedAt) < UPDATE_INTERVAL_MS) {
        Logger.info(TAG,
          `skip cn update, age=${Math.floor((now - meta.updatedAt) / 3600000)}h count=${meta.count}`);
        return true;
      }
      const mirrors: string[] = [
        'https://cdn.jsdelivr.net/gh/Loyalsoldier/geoip@release/text/cn.txt',
        'https://fastly.jsdelivr.net/gh/Loyalsoldier/geoip@release/text/cn.txt',
        'https://raw.githubusercontent.com/Loyalsoldier/geoip/release/text/cn.txt'
      ];
      for (let i = 0; i < mirrors.length; i++) {
        const url = mirrors[i];
        try {
          const buf = await CnRouteHelper.httpGetBuffer(url);
          if (!buf || buf.byteLength < MIN_CN_BYTES) {
            continue;
          }
          const text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
          const parsed = CnRouteHelper.parseText(text);
          if (parsed.length < 1000) {
            Logger.warn(TAG, `cn parse too few: ${parsed.length}`);
            continue;
          }
          const tmp = `${path}.tmp`;
          const lines: string[] = [];
          for (let j = 0; j < parsed.length; j++) {
            lines.push(`${parsed[j].address}/${parsed[j].prefixLength}`);
          }
          const body = `${lines.join('\n')}\n`;
          const bytes = new util.TextEncoder().encodeInto(body);
          const file = fs.openSync(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
          try {
            fs.writeSync(file.fd, bytes.buffer);
          } finally {
            fs.closeSync(file);
          }
          try {
            if (fs.accessSync(path)) {
              fs.unlinkSync(path);
            }
          } catch (_e) {
            // ignore
          }
          fs.renameSync(tmp, path);
          CnRouteHelper.cached = null;
          const host = CnRouteHelper.hostOf(url);
          CnRouteHelper.writeMeta(assetDir, { updatedAt: now, source: host, count: parsed.length });
          Logger.info(TAG, `cn update OK count=${parsed.length} via ${host}`);
          return true;
        } catch (e) {
          Logger.warn(TAG, `cn download: ${Logger.stringifyError(e as Error)}`);
        }
      }
      return false;
    } finally {
      CnRouteHelper.updating = false;
    }
  }

  /**
   * @returns ?? CIDR??? MAX_CN_ROUTES?
   */
  static async load(context: common.Context): Promise<CidrRoute[]> {
    if (CnRouteHelper.cached !== null) {
      return CnRouteHelper.cached;
    }
    const path = await CnRouteHelper.prepare(context);
    if (path) {
      try {
        const st = fs.statSync(path);
        const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
        try {
          const buf = new ArrayBuffer(st.size);
          fs.readSync(file.fd, buf);
          const text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
          const list = CnRouteHelper.parseText(text);
          CnRouteHelper.cached = list;
          Logger.info(TAG, `loaded cn cidrs=${list.length} from filesDir`);
          return list;
        } finally {
          fs.closeSync(file);
        }
      } catch (e) {
        Logger.warn(TAG, `read filesDir cn: ${Logger.stringifyError(e as Error)}`);
      }
    }
    try {
      const data = await context.resourceManager.getRawFileContent('cn-ipv4.txt');
      const text = util.TextDecoder.create('utf-8').decodeToString(
        new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
      );
      const list = CnRouteHelper.parseText(text);
      CnRouteHelper.cached = list;
      Logger.info(TAG, `loaded cn cidrs=${list.length} from rawfile`);
      return list;
    } catch (e) {
      Logger.error(TAG, `load cn failed: ${Logger.stringifyError(e as Error)}`);
      CnRouteHelper.cached = [];
      return [];
    }
  }

  private static parseText(text: string): CidrRoute[] {
    const lines = text.split(/\r?\n/);
    const list: CidrRoute[] = [];
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (!line || line.startsWith('#')) {
        continue;
      }
      const parts = line.split('/');
      if (parts.length !== 2) {
        continue;
      }
      const address = parts[0];
      const prefixLength = Number(parts[1]);
      if (!CnRouteHelper.isIPv4(address) || !Number.isInteger(prefixLength) ||
        prefixLength < 1 || prefixLength > 32) {
        continue;
      }
      list.push({ address: address, prefixLength: prefixLength });
      if (list.length >= MAX_CN_ROUTES) {
        break;
      }
    }
    return list;
  }

  private static async httpGetBuffer(url: string): Promise<ArrayBuffer> {
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        header: { 'User-Agent': 'OhosXray/1.0' }
      });
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        throw new Error(`HTTP ${resp.responseCode}`);
      }
      if (resp.result instanceof ArrayBuffer) {
        return resp.result;
      }
      throw new Error('unexpected response type');
    } finally {
      req.destroy();
    }
  }

  private static hostOf(url: string): string {
    const m = url.match(/^https?:\/\/([^/]+)/);
    return m ? m[1] : url;
  }

  private static metaPath(assetDir: string): string {
    return `${assetDir}/cn-update-meta.json`;
  }

  private static readMeta(assetDir: string): UpdateMeta | null {
    try {
      const path = CnRouteHelper.metaPath(assetDir);
      if (!fs.accessSync(path)) {
        return null;
      }
      const st = fs.statSync(path);
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        const buf = new ArrayBuffer(st.size);
        fs.readSync(file.fd, buf);
        const text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
        const obj = JSON.parse(text) as UpdateMeta;
        if (typeof obj.updatedAt === 'number') {
          return obj;
        }
      } finally {
        fs.closeSync(file);
      }
    } catch (_e) {
      // ignore
    }
    return null;
  }

  private static writeMeta(assetDir: string, meta: UpdateMeta): void {
    try {
      const path = CnRouteHelper.metaPath(assetDir);
      const text = JSON.stringify(meta);
      const bytes = new util.TextEncoder().encodeInto(text);
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, bytes.buffer);
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      Logger.warn(TAG, `writeMeta: ${Logger.stringifyError(e as Error)}`);
    }
  }

  private static isIPv4(host: string): boolean {
    const parts = host.split('.');
    if (parts.length !== 4) {
      return false;
    }
    for (let i = 0; i < 4; i++) {
      const n = Number(parts[i]);
      if (!Number.isInteger(n) || n < 0 || n > 255) {
        return false;
      }
    }
    return true;
  }
}
