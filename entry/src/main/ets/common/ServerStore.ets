import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';
import { ServerProfile } from '../model/ServerProfile';
import { Logger } from './Logger';

const TAG = 'ServerStore';
const STORE_NAME = 'ohos_xclient_servers';
const KEY_SERVERS = 'servers';
const KEY_ACTIVE_ID = 'active_id';
const KEY_PENDING_PROFILE = 'pending_profile';
const KEY_PENDING_SMART_ROUTE = 'pending_smart_route';
const KEY_VPN_CONNECTED = 'vpn_connected';
/**
 * 心跳文件（共享沙箱 filesDir）：Preferences 是每进程独立缓存，
 * 主进程看不到 :vpn 进程 flush 的写入，只能走文件。内容 `${ms}|${physIp}`。
 */
const VPN_HB_FILE = 'vpn_hb.txt';

export class ServerStore {
  private store: preferences.Preferences | null = null;
  private hbPath: string = '';

  async init(context: common.UIAbilityContext | common.Context): Promise<void> {
    this.store = await preferences.getPreferences(context, STORE_NAME);
    this.hbPath = `${context.filesDir}/${VPN_HB_FILE}`;
  }

  private ensureStore(): preferences.Preferences {
    if (!this.store) {
      throw new Error('ServerStore not initialized, call init() first');
    }
    return this.store;
  }

  async listServers(): Promise<ServerProfile[]> {
    const store = this.ensureStore();
    const raw = await store.get(KEY_SERVERS, '[]') as string;
    try {
      return JSON.parse(raw) as ServerProfile[];
    } catch (e) {
      Logger.error(TAG, `failed to parse stored servers: ${Logger.stringifyError(e)}`);
      return [];
    }
  }

  async saveServers(servers: ServerProfile[]): Promise<void> {
    const store = this.ensureStore();
    await store.put(KEY_SERVERS, JSON.stringify(servers));
    await store.flush();
  }

  async upsertServer(profile: ServerProfile): Promise<void> {
    const servers = await this.listServers();
    const idx = servers.findIndex(s => s.id === profile.id);
    if (idx >= 0) {
      servers[idx] = profile;
    } else {
      servers.push(profile);
    }
    await this.saveServers(servers);
  }

  async removeServer(id: string): Promise<void> {
    const servers = await this.listServers();
    await this.saveServers(servers.filter(s => s.id !== id));
  }

  async getActiveServerId(): Promise<string> {
    const store = this.ensureStore();
    return await store.get(KEY_ACTIVE_ID, '') as string;
  }

  async setActiveServerId(id: string): Promise<void> {
    const store = this.ensureStore();
    await store.put(KEY_ACTIVE_ID, id);
    await store.flush();
  }

  async setPendingProfile(profile: ServerProfile, smartRoute: boolean = true): Promise<void> {
    const store = this.ensureStore();
    await store.put(KEY_PENDING_PROFILE, JSON.stringify(profile));
    await store.put(KEY_PENDING_SMART_ROUTE, smartRoute ? '1' : '0');
    await store.flush();
  }

  async getPendingProfile(): Promise<ServerProfile | null> {
    const store = this.ensureStore();
    const raw = await store.get(KEY_PENDING_PROFILE, '') as string;
    if (!raw) return null;
    try {
      return JSON.parse(raw) as ServerProfile;
    } catch (e) {
      Logger.error(TAG, `failed to parse pending profile: ${Logger.stringifyError(e as Error)}`);
      return null;
    }
  }

  async getPendingSmartRoute(): Promise<boolean> {
    const store = this.ensureStore();
    const raw = await store.get(KEY_PENDING_SMART_ROUTE, '1') as string;
    return raw !== '0';
  }

  async getServerById(id: string): Promise<ServerProfile | null> {
    const servers = await this.listServers();
    const found = servers.find(s => s.id === id);
    return found ?? null;
  }

  async setVpnConnected(connected: boolean): Promise<void> {
    const store = this.ensureStore();
    await store.put(KEY_VPN_CONNECTED, connected ? '1' : '0');
    if (!connected) {
      this.clearHeartbeatFile();
    }
    await store.flush();
  }

  async getVpnConnected(): Promise<boolean> {
    const store = this.ensureStore();
    const raw = await store.get(KEY_VPN_CONNECTED, '0') as string;
    return raw === '1';
  }

  /**
   * VpnExtension 心跳：主进程用它判断隧道进程是否冻死。
   * 走共享沙箱文件而非 Preferences（跨进程缓存不可见）。
   */
  async touchVpnHeartbeat(physIp: string = ''): Promise<void> {
    if (!this.hbPath) {
      Logger.error(TAG, 'touchVpnHeartbeat: hbPath not initialized');
      return;
    }
    try {
      const file = fs.openSync(this.hbPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, `${Date.now()}|${physIp}`);
      fs.closeSync(file);
    } catch (e) {
      Logger.error(TAG, `touchVpnHeartbeat: ${Logger.stringifyError(e as Error)}`);
    }
  }

  async getVpnHeartbeatMs(): Promise<number> {
    const raw = this.readHeartbeatFile();
    if (!raw) {
      return 0;
    }
    const n = Number(raw.split('|')[0]);
    return Number.isFinite(n) ? n : 0;
  }

  async getVpnPhysIp(): Promise<string> {
    const raw = this.readHeartbeatFile();
    if (!raw) {
      return '';
    }
    const idx = raw.indexOf('|');
    return idx >= 0 ? raw.substring(idx + 1) : '';
  }

  private readHeartbeatFile(): string {
    if (!this.hbPath) {
      return '';
    }
    try {
      if (!fs.accessSync(this.hbPath)) {
        return '';
      }
      return fs.readTextSync(this.hbPath).trim();
    } catch (_e) {
      // 跨进程瞬时读到半截时按无心跳处理，调用方兜底
      return '';
    }
  }

  private clearHeartbeatFile(): void {
    if (!this.hbPath) {
      return;
    }
    try {
      if (fs.accessSync(this.hbPath)) {
        fs.unlinkSync(this.hbPath);
      }
    } catch (_e) {
      // ignore
    }
  }
}

export const serverStore = new ServerStore();
