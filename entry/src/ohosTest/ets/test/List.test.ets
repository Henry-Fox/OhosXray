import abilityTest from './Ability.test';
import linkParserTest from './LinkParser.test';
import subscriptionParserTest from './SubscriptionParser.test';

export default function testsuite() {
  abilityTest();
  linkParserTest();
  subscriptionParserTest();
}
