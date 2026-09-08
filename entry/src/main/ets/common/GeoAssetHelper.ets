import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import fs from '@ohos.file.fs';
import { Logger } from './Logger';

const TAG = 'GeoAssetHelper';

/** 社区维护规则：Loyalsoldier/v2ray-rules-dat（每日自动构建） */
const GEO_NAMES: string[] = ['geoip.dat', 'geosite.dat'];

/** 更新间隔：24 小时（上游约每天北京时间 6 点重建） */
const UPDATE_INTERVAL_MS = 24 * 60 * 60 * 1000;

const CONNECT_TIMEOUT_MS = 12000;
const READ_TIMEOUT_MS = 180000;

/** 最小有效体积（防止下到 HTML 错误页） */
const MIN_GEOIP_BYTES = 1000000;
const MIN_GEOSITE_BYTES = 500000;

interface UpdateMeta {
  updatedAt: number;
  source: string;
}

/**
 * geoip.dat / geosite.dat：
 * 1) 首次从 rawfile 落到 filesDir/xray-asset
 * 2) 后台从 Loyalsoldier 镜像自动更新（jsDelivr 优先，GitHub 兜底）
 *
 * 规则源：https://github.com/Loyalsoldier/v2ray-rules-dat
 */
export class GeoAssetHelper {
  private static updating: boolean = false;

  /**
   * @returns asset 目录绝对路径；失败返回空串
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
        Logger.error(TAG, `mkdir assetDir failed: ${Logger.stringifyError(e2 as Error)}`);
        return '';
      }
    }

    for (let i = 0; i < GEO_NAMES.length; i++) {
      const name = GEO_NAMES[i];
      const ok = await GeoAssetHelper.copyRawIfNeeded(context, assetDir, name);
      if (!ok) {
        Logger.error(TAG, `missing asset ${name}`);
        return '';
      }
    }
    Logger.info(TAG, `assets ready at ${assetDir}`);
    return assetDir;
  }

  /**
   * 后台尝试更新（不阻塞 UI）。已在更新中则跳过。
   */
  static updateInBackground(context: common.Context): void {
    GeoAssetHelper.tryUpdate(context).catch((e: Error) => {
      Logger.warn(TAG, `bg update: ${e.message}`);
    });
  }

  /**
   * 若超过更新间隔则从镜像下载覆盖本地 dat。
   */
  static async tryUpdate(context: common.Context): Promise<boolean> {
    if (GeoAssetHelper.updating) {
      return false;
    }
    GeoAssetHelper.updating = true;
    try {
      const assetDir = await GeoAssetHelper.prepare(context);
      if (!assetDir) {
        return false;
      }

      const meta = GeoAssetHelper.readMeta(assetDir);
      const now = Date.now();
      if (meta && (now - meta.updatedAt) < UPDATE_INTERVAL_MS) {
        Logger.info(TAG,
          `skip update, age=${Math.floor((now - meta.updatedAt) / 3600000)}h source=${meta.source}`);
        return true;
      }

      Logger.info(TAG, 'updating Loyalsoldier geoip/geosite…');
      let source = '';
      for (let i = 0; i < GEO_NAMES.length; i++) {
        const name = GEO_NAMES[i];
        const minSize = name === 'geoip.dat' ? MIN_GEOIP_BYTES : MIN_GEOSITE_BYTES;
        const used = await GeoAssetHelper.downloadOne(assetDir, name, minSize);
        if (!used) {
          Logger.warn(TAG, `update failed for ${name}, keep local`);
          return false;
        }
        source = used;
      }
      GeoAssetHelper.writeMeta(assetDir, { updatedAt: now, source: source });
      Logger.info(TAG, `update OK via ${source}`);
      return true;
    } catch (e) {
      Logger.warn(TAG, `tryUpdate: ${Logger.stringifyError(e as Error)}`);
      return false;
    } finally {
      GeoAssetHelper.updating = false;
    }
  }

  private static mirrorsFor(name: string): string[] {
    return [
      `https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/${name}`,
      `https://fastly.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/${name}`,
      `https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/${name}`
    ];
  }

  private static async downloadOne(assetDir: string, name: string, minSize: number): Promise<string> {
    const mirrors = GeoAssetHelper.mirrorsFor(name);
    for (let i = 0; i < mirrors.length; i++) {
      const url = mirrors[i];
      const host = GeoAssetHelper.hostOf(url);
      try {
        const buf = await GeoAssetHelper.httpGetBuffer(url);
        if (!buf || buf.byteLength < minSize) {
          Logger.warn(TAG, `${name} from ${host} too small: ${buf ? buf.byteLength : 0}`);
          continue;
        }
        const tmp = `${assetDir}/${name}.tmp`;
        const dest = `${assetDir}/${name}`;
        const file = fs.openSync(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        try {
          fs.writeSync(file.fd, buf);
        } finally {
          fs.closeSync(file);
        }
        try {
          if (fs.accessSync(dest)) {
            fs.unlinkSync(dest);
          }
        } catch (_e) {
          // ignore
        }
        fs.renameSync(tmp, dest);
        Logger.info(TAG, `downloaded ${name} size=${buf.byteLength} via ${host}`);
        return host;
      } catch (e) {
        Logger.warn(TAG, `${name} ${host}: ${Logger.stringifyError(e as Error)}`);
      }
    }
    return '';
  }

  private static async httpGetBuffer(url: string): Promise<ArrayBuffer> {
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        header: {
          'User-Agent': 'OhosXray/1.0'
        }
      });
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        throw new Error(`HTTP ${resp.responseCode}`);
      }
      const result = resp.result;
      if (result instanceof ArrayBuffer) {
        return result;
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
    return `${assetDir}/update-meta.json`;
  }

  private static readMeta(assetDir: string): UpdateMeta | null {
    try {
      const path = GeoAssetHelper.metaPath(assetDir);
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
      const path = GeoAssetHelper.metaPath(assetDir);
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

  private static async copyRawIfNeeded(context: common.Context, assetDir: string, name: string): Promise<boolean> {
    const dest = `${assetDir}/${name}`;
    try {
      if (fs.accessSync(dest)) {
        const st = fs.statSync(dest);
        if (st.size > 1024) {
          return true;
        }
      }
    } catch (_e) {
      // continue copy
    }

    try {
      const data = await context.resourceManager.getRawFileContent(name);
      const ab = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
      const file = fs.openSync(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, ab);
      fs.closeSync(file);
      Logger.info(TAG, `copied rawfile ${name} size=${data.byteLength}`);
      return true;
    } catch (e) {
      Logger.error(TAG, `copy ${name} failed: ${Logger.stringifyError(e as Error)}`);
      return false;
    }
  }
}
