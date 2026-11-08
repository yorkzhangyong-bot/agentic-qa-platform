<!-- agentic-qa-defect: 0000000000000000000000000000000000000000 -->
# [Agentic QA] Order total ignores the second item (Checkout › shows the order total)

## Summary
After two items are added to the cart, the checkout page shows a total that is $2.00 too low. Spotted by @qa-team
in the `@smoke` run.

## Expected vs Actual
- **Expected:** the order total is $20.00 (two items at $10.00).
- **Actual:** the order total is $18.00.

## Steps to reproduce
1. Open the shop and add the "Coffee mug" to the cart twice.
2. Go to the checkout page.
3. Look at the order total.

## Evidence
- Error: `Error: Timed out 5000ms waiting for expect(getByTestId('order-total')).toHaveText("$20.00") but received "$18.00" (order 7f3e9a1c)`
- Failing step: `tests/checkout.spec.ts:14`
- Page: https://staging.example.com/checkout

## Triage reasoning
The total element was found, so the locator works; the value it shows is wrong.

## Environment
- Commit: `0123456789abcdef0123456789abcdef01234567`
- App URL: https://staging.example.com
- Framework: playwright
- Engine / model: opencode / deepseek/deepseek-flash

## Links
- Workflow run: https://github.com/acme/shop/actions/runs/42
- Artifacts: `test-results` (JUnit reports), `triage` (failures.json, triage.json), `defects` (these reports)
