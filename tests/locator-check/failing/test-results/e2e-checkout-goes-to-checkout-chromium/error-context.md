# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: e2e/checkout.spec.ts >> goes to checkout
- Location: tests/e2e/checkout.spec.ts:3:5

# Error details

```
Error: locator.click: Test timeout of 30000ms exceeded.
Call log:
  - waiting for getByRole('button', { name: 'Checkout' })
```

# Page snapshot

```yaml
- main [ref=e2]:
  - heading "Your cart" [level=1] [ref=e3]
  - link "Checkout" [ref=e4] [cursor=pointer]:
    - /url: /checkout
```