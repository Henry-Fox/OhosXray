import { describe, it, expect } from '@ohos/hypium';
import {
  classifyImportInput,
  validateSubscriptionUrl,
  describeSubscriptionError,
  SubscriptionError,
  SUBSCRIPTION_ERROR_INVALID_URL,
  SUBSCRIPTION_ERROR_HTTP_STATUS,
  SUBSCRIPTION_MAX_BYTES,
  SUBSCRIPTION_CONNECT_TIMEOUT_MS,
  SUBSCRIPTION_READ_TIMEOUT_MS,
  SUBSCRIPTION_MAX_REDIRECTS
} from '../main/ets/model/ImportInput';
import { mergeImportedServers, BatchMergeResult } from '../main/ets/model/ServerBatchMerge';
import { ServerProfile, createEmptyProfile } from '../main/ets/model/ServerProfile';
import { SubscriptionParseResult } from '../main/ets/model/SubscriptionParser';
import { SubscriptionImportSession } from '../main/ets/common/SubscriptionImportSession';

const SECRET_TOKEN = 'tok3n-secret-value';
const FAKE_UUID = '00000000-0000-4000-8000-000000000000';

/**
 * @param urlText 待校验地址
 * @returns 校验失败时的错误；通过时返回 null
 */
function urlError(urlText: string): Error | null {
  try {
    validateSubscriptionUrl(urlText);
  } catch (e) {
    return e as Error;
  }
  return null;
}

/**
 * 本地测试运行在 PC 上，系统接口（util、url 等）均为自动 mock，
 * 只放不依赖系统能力的纯逻辑用例；依赖系统接口的用例放 ohosTest。
 */
export default function localUnitTest() {
  describe('importInput', () => {
    it('classifiesDirectLinks', 0, () => {
      expect(classifyImportInput('vless://x@h:1')).assertEqual('direct');
      expect(classifyImportInput('  VMESS://abc  ')).assertEqual('direct');
    });

    it('classifiesSubscriptions', 0, () => {
      expect(classifyImportInput('https://sub.example.com/s/abc')).assertEqual('subscription');
      expect(classifyImportInput('\nHTTP://sub.example.com:2096/sub/x\n')).assertEqual('subscription');
    });

    it('rejectsUnsupportedInput', 0, () => {
      expect(classifyImportInput('')).assertEqual('unsupported');
      expect(classifyImportInput('trojan://p@h:443')).assertEqual('unsupported');
      expect(classifyImportInput('sub.example.com/s/abc')).assertEqual('unsupported');
    });

    it('acceptsHttpAndHttpsUrls', 0, () => {
      expect(validateSubscriptionUrl(` https://sub.example.com/s/${SECRET_TOKEN}?flag=1 `))
        .assertEqual(`https://sub.example.com/s/${SECRET_TOKEN}?flag=1`);
      expect(validateSubscriptionUrl('http://10.0.0.1:2096/sub/abc')).assertEqual('http://10.0.0.1:2096/sub/abc');
      expect(validateSubscriptionUrl('https://[2001:db8::1]:8443/sub')).assertEqual('https://[2001:db8::1]:8443/sub');
    });

    it('rejectsInvalidUrls', 0, () => {
      const bad = [
        'sub.example.com/s/abc',
        'ftp://sub.example.com/s',
        `https://user:${SECRET_TOKEN}@sub.example.com/s`,
        'https:///s/abc',
        'https://sub.example.com:99999/s',
        'https://sub.example.com/s path'
      ];
      for (const item of bad) {
        const err = urlError(item);
        expect(err !== null).assertTrue();
        expect((err as Error).message).assertEqual(SUBSCRIPTION_ERROR_INVALID_URL);
      }
    });

    it('errorMessagesDoNotEchoSecrets', 0, () => {
      const err = urlError(`https://user:${SECRET_TOKEN}@sub.example.com/s/${FAKE_UUID}?t=${SECRET_TOKEN}`) as Error;
      const text = describeSubscriptionError(err);
      expect(text.length > 0).assertTrue();
      expect(text.indexOf(SECRET_TOKEN)).assertEqual(-1);
      expect(text.indexOf(FAKE_UUID)).assertEqual(-1);
      expect(text.indexOf('sub.example.com')).assertEqual(-1);
    });

    it('describesHttpStatusAndUnknownErrors', 0, () => {
      const statusError = new SubscriptionError(SUBSCRIPTION_ERROR_HTTP_STATUS, 404) as Error;
      expect(describeSubscriptionError(statusError).indexOf('404') >= 0).assertTrue();
      const unknown = describeSubscriptionError(new Error(`boom ${SECRET_TOKEN}`));
      expect(unknown.indexOf(SECRET_TOKEN)).assertEqual(-1);
    });

    it('pinsRequestLimits', 0, () => {
      expect(SUBSCRIPTION_MAX_BYTES).assertEqual(2 * 1024 * 1024);
      expect(SUBSCRIPTION_CONNECT_TIMEOUT_MS).assertEqual(12000);
      expect(SUBSCRIPTION_READ_TIMEOUT_MS).assertEqual(30000);
      expect(SUBSCRIPTION_MAX_REDIRECTS).assertEqual(3);
    });
  });

  describe('serverBatchMerge', () => {
    it('insertsNewNodeWithFreshId', 0, () => {
      const result = merge([], [node('', UUID_A, 'a.example.com', 443, 'a')]);
      expect(result.added).assertEqual(1);
      expect(result.servers[0].id).assertEqual('new-1');
      expect(result.servers[0].createdAt).assertEqual(NOW);
    });

    it('updatesExactEndpointInPlace', 0, () => {
      const existing = [node('x1', UUID_A, 'a.example.com', 443, 'old')];
      const incoming = node('', UUID_A, 'A.example.com', 443, 'new');
      incoming.network = 'ws';
      const result = merge(existing, [incoming]);
      expect(result.updated).assertEqual(1);
      expect(result.added).assertEqual(0);
      expect(result.servers.length).assertEqual(1);
      expect(result.servers[0].id).assertEqual('x1');
      expect(result.servers[0].createdAt).assertEqual(1);
      expect(result.servers[0].remark).assertEqual('new');
      expect(result.servers[0].network).assertEqual('ws');
    });

    it('updatesMovedEndpointBySameRemark', 0, () => {
      const existing = [node('x1', UUID_A, 'old.example.com', 443, 'node-a')];
      const result = merge(existing, [node('', UUID_A, 'new.example.com', 8443, 'node-a')]);
      expect(result.updated).assertEqual(1);
      expect(result.servers.length).assertEqual(1);
      expect(result.servers[0].id).assertEqual('x1');
      expect(result.servers[0].address).assertEqual('new.example.com');
      expect(result.servers[0].port).assertEqual(8443);
    });

    it('addsWhenRemarkFallbackIsAmbiguous', 0, () => {
      const existing = [
        node('x1', UUID_A, 'a.example.com', 443, 'same'),
        node('x2', UUID_A, 'b.example.com', 443, 'same')
      ];
      const result = merge(existing, [node('', UUID_A, 'c.example.com', 443, 'same')]);
      expect(result.added).assertEqual(1);
      expect(result.updated).assertEqual(0);
      expect(result.servers.length).assertEqual(3);
    });

    it('keepsSameRemarkWithDifferentUuidSeparate', 0, () => {
      const existing = [node('x1', UUID_A, 'a.example.com', 443, 'same')];
      const result = merge(existing, [node('', UUID_B, 'b.example.com', 443, 'same')]);
      expect(result.added).assertEqual(1);
      expect(result.servers[0].address).assertEqual('a.example.com');
    });

    it('updatesEachExistingRecordOnce', 0, () => {
      const existing = [node('x1', UUID_A, 'a.example.com', 443, 'a')];
      const result = merge(existing, [
        node('', UUID_A, 'a.example.com', 443, 'first'),
        node('', UUID_A, 'a.example.com', 443, 'second')
      ]);
      expect(result.updated).assertEqual(1);
      expect(result.skipped).assertEqual(1);
      expect(result.servers[0].remark).assertEqual('first');
    });

    it('prefersEndpointMatchOverRemarkFallback', 0, () => {
      const existing = [node('x1', UUID_A, 'a.example.com', 443, 'same')];
      const result = merge(existing, [
        node('', UUID_A, 'a.example.com', 8443, 'same'),
        node('', UUID_A, 'a.example.com', 443, 'same')
      ]);
      expect(result.updated).assertEqual(1);
      expect(result.added).assertEqual(1);
      expect(result.servers[0].id).assertEqual('x1');
      expect(result.servers[0].port).assertEqual(443);
      expect(result.servers[1].port).assertEqual(8443);
    });

    it('keepsUntouchedRecordsAndOrder', 0, () => {
      const existing = [
        node('x1', UUID_A, 'a.example.com', 443, 'a'),
        node('x2', UUID_B, 'b.example.com', 443, 'b'),
        node('x3', UUID_A, 'c.example.com', 443, 'c')
      ];
      const result = merge(existing, [
        node('', UUID_B, 'b.example.com', 443, 'b2'),
        node('', UUID_B, 'd.example.com', 443, 'd')
      ]);
      expect(result.servers.map((s: ServerProfile) => s.id).join(',')).assertEqual('x1,x2,x3,new-1');
      expect(result.servers[1].remark).assertEqual('b2');
      expect(result.servers[2].remark).assertEqual('c');
      expect(existing[1].remark).assertEqual('b');
    });
  });

  describe('subscriptionImportSession', () => {
    it('takesOnceThenEmpty', 0, () => {
      SubscriptionImportSession.set(sessionData());
      const taken = SubscriptionImportSession.take();
      expect(taken !== null).assertTrue();
      expect((taken as SubscriptionParseResult).profiles.length).assertEqual(1);
      expect((taken as SubscriptionParseResult).invalidCount).assertEqual(2);
      expect(SubscriptionImportSession.take() === null).assertTrue();
    });

    it('clearRemovesPendingData', 0, () => {
      SubscriptionImportSession.set(sessionData());
      SubscriptionImportSession.clear();
      expect(SubscriptionImportSession.take() === null).assertTrue();
    });

    it('storesCopyWithoutUrl', 0, () => {
      const source = sessionData();
      SubscriptionImportSession.set(source);
      source.profiles[0].remark = 'mutated';
      source.profiles.push(node('x9', UUID_B, 'z.example.com', 443, 'z'));
      const taken = SubscriptionImportSession.take() as SubscriptionParseResult;
      expect(taken.profiles.length).assertEqual(1);
      expect(taken.profiles[0].remark).assertEqual('a');
      expect(taken.missingRealityKeyCount).assertEqual(1);
      expect(Object.keys(taken).sort().join(','))
        .assertEqual('duplicateCount,invalidCount,missingRealityKeyCount,profiles');
    });
  });
}

/**
 * @returns 会话测试用解析结果
 */
function sessionData(): SubscriptionParseResult {
  const data: SubscriptionParseResult = {
    profiles: [node('p1', UUID_A, 'a.example.com', 443, 'a')],
    invalidCount: 2,
    duplicateCount: 1,
    missingRealityKeyCount: 1
  };
  return data;
}

const NOW = 1700000000000;
const UUID_A = '00000000-0000-4000-8000-00000000000a';
const UUID_B = '00000000-0000-4000-8000-00000000000b';

/**
 * 构造测试节点。
 * @param id 本地 id
 * @param uuid 用户 UUID
 * @param address 地址
 * @param port 端口
 * @param remark 备注名
 * @returns 节点
 */
function node(id: string, uuid: string, address: string, port: number, remark: string): ServerProfile {
  const profile = createEmptyProfile();
  profile.id = id;
  profile.createdAt = 1;
  profile.uuid = uuid;
  profile.address = address;
  profile.port = port;
  profile.remark = remark;
  return profile;
}

/**
 * 以可预测的 id 生成器执行合并。
 * @param existing 已有节点
 * @param imported 导入节点
 * @returns 合并结果
 */
function merge(existing: ServerProfile[], imported: ServerProfile[]): BatchMergeResult {
  let seq = 0;
  return mergeImportedServers(existing, imported, (): string => {
    seq++;
    return `new-${seq}`;
  }, NOW);
}
