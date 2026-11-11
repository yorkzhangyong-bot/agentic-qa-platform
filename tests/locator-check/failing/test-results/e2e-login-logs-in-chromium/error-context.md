# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: e2e/login.spec.ts >> logs in
- Location: tests/e2e/login.spec.ts:3:5

# Error details

```
Error: locator.click: Test timeout of 30000ms exceeded.
Call log:
  - waiting for getByTestId('login-btn')
```

# Page snapshot

```yaml
- main [ref=e2]:
  - textbox "Email" [ref=e3]: qa@example.com
  - button "Sign in" [ref=e4] [cursor=pointer]
```