import { describe, it, expect } from '@ohos/hypium';
import { SubscriptionService } from '../../../main/ets/common/SubscriptionService';
import { describeSubscriptionError, SUBSCRIPTION_ERROR_INVALID_URL } from '../../../main/ets/model/ImportInput';

const SECRET_TOKEN = 'tok3n-secret-value';

export default function subscriptionServiceTest() {
  describe('subscriptionService', () => {
    it('rejectsInvalidUrlWithoutRequest', 0, async () => {
      let category = '';
      let text = '';
      try {
        await SubscriptionService.fetch(`ftp://sub.example.com/s/${SECRET_TOKEN}`);
      } catch (e) {
        category = (e as Error).message;
        text = describeSubscriptionError(e as Error);
      }
      expect(category).assertEqual(SUBSCRIPTION_ERROR_INVALID_URL);
      expect(text.indexOf(SECRET_TOKEN)).assertEqual(-1);
    });
  });
}
