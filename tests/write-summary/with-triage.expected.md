## Test results: playwright @ [`0123456`](https://github.com/acme/shop/commit/0123456789abcdef0123456789abcdef01234567)

**Total** 2 · **Passed** 1 · **Failed** 1 · **Skipped** 0 · **Duration** 3.2s

### Failed tests

| Test | File | Error | Triage |
| --- | --- | --- | --- |
| Checkout › applies a coupon | tests/checkout.spec.ts | Error: locator.click: Test timeout of 30000ms exceeded. | **SELECTOR\_DRIFT**: Timed out on getByTestId('apply-coupon'); the same Apply button now has data-testid='coupon-apply'. |

