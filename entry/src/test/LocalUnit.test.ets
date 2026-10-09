import { describe, it, expect } from '@ohos/hypium';

/**
 * 本地测试运行在 PC 上，系统接口（util、url 等）均为自动 mock，
 * 只放不依赖系统能力的纯逻辑用例；依赖系统接口的用例放 ohosTest。
 */
export default function localUnitTest() {
  describe('localUnitTest', () => {
    it('runtimeAvailable', 0, () => {
      expect('ok').assertEqual('ok');
    });
  });
}
