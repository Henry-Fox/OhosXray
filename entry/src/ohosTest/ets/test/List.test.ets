import abilityTest from './Ability.test';
import linkParserTest from './LinkParser.test';
import subscriptionParserTest from './SubscriptionParser.test';
import subscriptionServiceTest from './SubscriptionService.test';

export default function testsuite() {
  abilityTest();
  linkParserTest();
  subscriptionParserTest();
  subscriptionServiceTest();
}
