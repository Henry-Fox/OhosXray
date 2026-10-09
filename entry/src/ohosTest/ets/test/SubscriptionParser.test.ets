import { describe, it, expect } from '@ohos/hypium';
import { util } from '@kit.ArkTS';
import {
  parseSubscriptionPayload,
  isUsableProfile,
  hasRealityKey,
  SUBSCRIPTION_ERROR_EMPTY,
  SUBSCRIPTION_ERROR_NO_NODES,
  SUBSCRIPTION_ERROR_REALITY_KEY
} from '../../../main/ets/model/SubscriptionParser';
import { parseShareLink } from '../../../main/ets/model/LinkParser';
import { ProxyProtocol, createEmptyProfile } from '../../../main/ets/model/ServerProfile';

const UUID_A = '00000000-0000-4000-8000-00000000000a';
const UUID_B = '00000000-0000-4000-8000-00000000000b';
const LINK_A = `vless://${UUID_A}@a.example.com:443?security=tls&type=tcp#node-a`;
const LINK_B = `vless://${UUID_B}@b.example.com:8443?security=reality&pbk=k&sid=s#node-b`;

function toBase64(text: string): string {
  const bytes = new util.TextEncoder().encodeInto(text);
  return new util.Base64Helper().encodeToStringSync(bytes, util.Type.BASIC);
}

function toUrlSafeBase64(text: string): string {
  return toBase64(text).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function vmessLink(uuid: string, host: string, port: string, remark: string): string {
  const json = `{"v":"2","ps":"${remark}","add":"${host}","port":"${port}","id":"${uuid}","net":"ws","tls":"tls"}`;
  return `vmess://${toBase64(json)}`;
}

function errorCategoryOf(payload: string): string {
  try {
    parseSubscriptionPayload(payload);
  } catch (e) {
    return (e as Error).message;
  }
  return '';
}

export default function subscriptionParserTest() {
  describe('subscriptionParser', () => {
    it('parsesPlainTextLines', 0, () => {
      const result = parseSubscriptionPayload(`${LINK_A}\n${LINK_B}\n`);
      expect(result.profiles.length).assertEqual(2);
      expect(result.profiles[0].address).assertEqual('a.example.com');
      expect(result.profiles[0].originalLink).assertEqual(LINK_A);
      expect(result.profiles[1].tls).assertEqual('reality');
      expect(result.invalidCount).assertEqual(0);
      expect(result.duplicateCount).assertEqual(0);
    });

    it('parsesCrlfAndBlankLines', 0, () => {
      const result = parseSubscriptionPayload(`\r\n${LINK_A}\r\n\r\n  ${LINK_B}  \r\n`);
      expect(result.profiles.length).assertEqual(2);
      expect(result.profiles[1].originalLink).assertEqual(LINK_B);
    });

    it('parsesStandardBase64', 0, () => {
      const result = parseSubscriptionPayload(toBase64(`${LINK_A}\n${LINK_B}`));
      expect(result.profiles.length).assertEqual(2);
      expect(result.profiles[1].uuid).assertEqual(UUID_B);
    });

    it('parsesUrlSafeBase64WithoutPadding', 0, () => {
      const payload = toUrlSafeBase64(`${LINK_A}\n${LINK_B}\n${vmessLink(UUID_A, 'c.example.com', '2053', 'node-c')}`);
      const result = parseSubscriptionPayload(payload);
      expect(result.profiles.length).assertEqual(3);
      expect(result.profiles[2].protocol).assertEqual(ProxyProtocol.VMESS);
      expect(result.profiles[2].port).assertEqual(2053);
    });

    it('parsesBase64WrappedAcrossLines', 0, () => {
      const encoded = toBase64(`${LINK_A}\n${LINK_B}`);
      const wrapped = `${encoded.substring(0, 40)}\n${encoded.substring(40)}`;
      expect(parseSubscriptionPayload(wrapped).profiles.length).assertEqual(2);
    });

    it('keepsValidSiblingsOfInvalidLines', 0, () => {
      const payload = [
        LINK_A,
        'ss://Y2hhY2hhMjA6cGFzcw@ss.example.com:8388#ss',
        'vless://broken',
        'vmess://not-json',
        vmessLink(UUID_B, 'd.example.com', 'abc', 'bad-port'),
        'just some text'
      ].join('\n');
      const result = parseSubscriptionPayload(payload);
      expect(result.profiles.length).assertEqual(1);
      expect(result.invalidCount).assertEqual(5);
    });

    it('removesDuplicateLinksAndEndpoints', 0, () => {
      const sameEndpointRenamed = `vless://${UUID_A}@A.example.com:443?security=tls#renamed`;
      const result = parseSubscriptionPayload(`${LINK_A}\n${LINK_A}\n${sameEndpointRenamed}\n${LINK_B}`);
      expect(result.profiles.length).assertEqual(2);
      expect(result.profiles[0].remark).assertEqual('node-a');
      expect(result.duplicateCount).assertEqual(2);
    });

    it('keepsSameRemarkWithDifferentEndpoints', 0, () => {
      const first = `vless://${UUID_A}@a.example.com:443?security=tls#same`;
      const second = `vless://${UUID_A}@a.example.com:8443?security=tls#same`;
      const result = parseSubscriptionPayload(`${first}\n${second}`);
      expect(result.profiles.length).assertEqual(2);
      expect(result.duplicateCount).assertEqual(0);
    });

    it('rejectsRealityWithoutPublicKey', 0, () => {
      const noPbk = `vless://${UUID_A}@r.example.com:4436?security=reality&sid=85b4&sni=dl.google.com&type=tcp#no-pbk`;
      const result = parseSubscriptionPayload(`${noPbk}\n${LINK_B}`);
      expect(result.profiles.length).assertEqual(1);
      expect(result.profiles[0].remark).assertEqual('node-b');
      expect(result.invalidCount).assertEqual(1);
      expect(result.missingRealityKeyCount).assertEqual(1);
      expect(hasRealityKey(parseShareLink(noPbk))).assertFalse();
      expect(errorCategoryOf(noPbk)).assertEqual(SUBSCRIPTION_ERROR_REALITY_KEY);
    });

    it('rejectsEmptyPayload', 0, () => {
      expect(errorCategoryOf('')).assertEqual(SUBSCRIPTION_ERROR_EMPTY);
      expect(errorCategoryOf(' \r\n ')).assertEqual(SUBSCRIPTION_ERROR_EMPTY);
    });

    it('rejectsUnsupportedOnlyPayload', 0, () => {
      expect(errorCategoryOf('trojan://pass@t.example.com:443\nss://abc')).assertEqual(SUBSCRIPTION_ERROR_NO_NODES);
    });

    it('fallsBackWhenBase64LookingTextHasNoLinks', 0, () => {
      expect(errorCategoryOf('abcdEFGH')).assertEqual(SUBSCRIPTION_ERROR_NO_NODES);
    });

    it('errorsDoNotEchoPayload', 0, () => {
      const message = errorCategoryOf(`trojan://${UUID_A}@secret.example.com:443`);
      expect(message.indexOf(UUID_A)).assertEqual(-1);
      expect(message.indexOf('secret')).assertEqual(-1);
    });

    it('validatesUsableProfile', 0, () => {
      const profile = createEmptyProfile();
      profile.address = 'a.example.com';
      profile.uuid = UUID_A;
      profile.port = 443;
      expect(isUsableProfile(profile)).assertTrue();
      profile.port = 0;
      expect(isUsableProfile(profile)).assertFalse();
      profile.port = 65536;
      expect(isUsableProfile(profile)).assertFalse();
      profile.port = 443;
      profile.uuid = ' ';
      expect(isUsableProfile(profile)).assertFalse();
    });
  });
}
