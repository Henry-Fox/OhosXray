import { util } from '@kit.ArkTS';
import { ServerProfile } from './ServerProfile';
import { endpointKey } from './SubscriptionParser';

/**
 * 批量导入统计。
 */
export interface BatchImportSummary {
  added: number;
  updated: number;
  skipped: number;
}

/**
 * 批量合并结果：合并后的完整节点列表与统计。
 */
export interface BatchMergeResult extends BatchImportSummary {
  servers: ServerProfile[];
}

/**
 * @returns 新的本地节点 id
 */
function generateId(): string {
  return util.generateRandomUUID();
}

/**
 * @param profile 节点
 * @returns 协议 + UUID + 备注名，用于端点变更后的兜底匹配
 */
function remarkKey(profile: ServerProfile): string {
  return `${profile.protocol}|${profile.uuid.trim()}|${(profile.remark ?? '').trim()}`;
}

/**
 * @param profile 节点
 * @returns 深拷贝，避免与调用方共享引用
 */
function cloneProfile(profile: ServerProfile): ServerProfile {
  return JSON.parse(JSON.stringify(profile)) as ServerProfile;
}

/**
 * 把导入节点合并进已有列表。
 * 第一轮按端点（协议 + UUID + 地址 + 端口）精确匹配；第二轮对未匹配的导入节点，
 * 仅当本地恰有一条同「协议 + UUID + 备注名」记录且本批也只有一条时才视为同一节点（端点已变更）。
 * 命中时保留本地 id 与 createdAt；每条本地记录每批最多被更新一次。
 * @param existing 已有节点
 * @param imported 待导入节点
 * @param newId 新节点 id 生成器
 * @param now 新节点创建时间
 * @returns 合并结果
 */
export function mergeImportedServers(existing: ServerProfile[], imported: ServerProfile[],
  newId: () => string = generateId, now: number = Date.now()): BatchMergeResult {
  const servers = existing.map(cloneProfile);
  const endpointIndex = new Map<string, number>();
  const remarkIndex = new Map<string, number[]>();
  servers.forEach((server: ServerProfile, index: number) => {
    const ek = endpointKey(server);
    if (!endpointIndex.has(ek)) {
      endpointIndex.set(ek, index);
    }
    const rk = remarkKey(server);
    const list = remarkIndex.get(rk) ?? [];
    list.push(index);
    remarkIndex.set(rk, list);
  });

  const SKIP = -2;
  const NEW = -1;
  const targets: number[] = imported.map((): number => NEW);
  const matched = new Set<number>();

  imported.forEach((profile: ServerProfile, i: number) => {
    const index = endpointIndex.get(endpointKey(profile));
    if (index === undefined) {
      return;
    }
    if (matched.has(index)) {
      targets[i] = SKIP;
    } else {
      matched.add(index);
      targets[i] = index;
    }
  });

  const pendingByRemark = new Map<string, number>();
  imported.forEach((profile: ServerProfile, i: number) => {
    if (targets[i] === NEW) {
      const rk = remarkKey(profile);
      pendingByRemark.set(rk, (pendingByRemark.get(rk) ?? 0) + 1);
    }
  });
  imported.forEach((profile: ServerProfile, i: number) => {
    if (targets[i] !== NEW) {
      return;
    }
    const rk = remarkKey(profile);
    const candidates = remarkIndex.get(rk) ?? [];
    if (candidates.length === 1 && pendingByRemark.get(rk) === 1 && !matched.has(candidates[0])) {
      matched.add(candidates[0]);
      targets[i] = candidates[0];
    }
  });

  const result: BatchMergeResult = { servers: servers, added: 0, updated: 0, skipped: 0 };
  const addedEndpoints = new Set<string>();
  imported.forEach((profile: ServerProfile, i: number) => {
    const target = targets[i];
    if (target === SKIP) {
      result.skipped++;
      return;
    }
    const next = cloneProfile(profile);
    if (target >= 0) {
      next.id = servers[target].id;
      next.createdAt = servers[target].createdAt;
      servers[target] = next;
      result.updated++;
      return;
    }
    const ek = endpointKey(profile);
    if (addedEndpoints.has(ek)) {
      result.skipped++;
      return;
    }
    addedEndpoints.add(ek);
    next.id = newId();
    next.createdAt = now;
    servers.push(next);
    result.added++;
  });
  return result;
}
