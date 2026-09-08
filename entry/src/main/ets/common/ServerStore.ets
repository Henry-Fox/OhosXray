import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { ServerProfile } from '../model/ServerProfile';
import { Logger } from './Logger';

const TAG = 'ServerStore';
const STORE_NAME = 'ohos_xclient_servers';
const KEY_SERVERS = 'servers';
const KEY_ACTIVE_ID = 'active_id';
const KEY_PENDING_PROFILE = 'pending_profile';
const KEY_VPN_CONNECTED = 'vpn_connected';

export class ServerStore {
  private store: preferences.Preferences | null = null;

  async init(context: common.UIAbilityContext | common.Context): Promise<void> {
    this.store = await preferences.getPreferences(context, STORE_NAME);
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

  async setPendingProfile(profile: ServerProfile): Promise<void> {
    const store = this.ensureStore();
    await store.put(KEY_PENDING_PROFILE, JSON.stringify(profile));
    await store.flush();
  }

  async getPendingProfile(): Promise<ServerProfile | null> {
    const store = this.ensureStore();
    const raw = await store.get(KEY_PENDING_PROFILE, '') as string;
    if (!raw) return null;
    try {
      return JSON.parse(raw) as ServerProfile;
    } catch (e) {
      Logger.error(TAG, `failed to parse pending profile: ${Logger.stringifyError(e)}`);
      return null;
    }
  }

  async getServerById(id: string): Promise<ServerProfile | null> {
    const servers = await this.listServers();
    const found = servers.find(s => s.id === id);
    return found ?? null;
  }

  async setVpnConnected(connected: boolean): Promise<void> {
    const store = this.ensureStore();
    await store.put(KEY_VPN_CONNECTED, connected ? '1' : '0');
    await store.flush();
  }

  async getVpnConnected(): Promise<boolean> {
    const store = this.ensureStore();
    const raw = await store.get(KEY_VPN_CONNECTED, '0') as string;
    return raw === '1';
  }
}

export const serverStore = new ServerStore();
