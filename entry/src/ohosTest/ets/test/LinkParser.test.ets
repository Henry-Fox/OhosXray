import { describe, it, expect } from '@ohos/hypium';
import { parseShareLink } from '../../../main/ets/model/LinkParser';
import { ProxyProtocol } from '../../../main/ets/model/ServerProfile';

const FAKE_UUID = '00000000-0000-4000-8000-000000000000';

export default function linkParserTest() {
  describe('linkParserSmoke', () => {
    it('parsesDirectVlessLink', 0, () => {
      const profile = parseShareLink(`vless://${FAKE_UUID}@example.com:8443?security=tls&type=ws#demo`);
      expect(profile.protocol).assertEqual(ProxyProtocol.VLESS);
      expect(profile.address).assertEqual('example.com');
      expect(profile.port).assertEqual(8443);
      expect(profile.uuid).assertEqual(FAKE_UUID);
      expect(profile.remark).assertEqual('demo');
    });
  });
}
