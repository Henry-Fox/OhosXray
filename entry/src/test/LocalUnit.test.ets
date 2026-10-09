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
}
