# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: e2e/signin.spec.ts >> signs in
- Location: tests/e2e/signin.spec.ts:3:5

# Error details

```
Error: locator.click: Test timeout of 30000ms exceeded.
Call log:
  - waiting for getByRole('button', { name: 'Sign in' })
```

# Page snapshot

```yaml
- main [ref=e2]:
  - button "Log in" [ref=e3] [cursor=pointer]
```