# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: account.spec.ts >> cancels through the page object
- Location: tests/account.spec.ts:16:5

# Error details

```
Error: locator.click: Test timeout of 30000ms exceeded.
Call log:
  - waiting for getByRole('button', { name: 'Delete' })
```

# Page snapshot

```yaml
- generic [ref=e1]:
  - banner [ref=e2]:
    - link "Home" [ref=e3] [cursor=pointer]:
      - /url: "#home"
    - link "Settings" [ref=e4] [cursor=pointer]:
      - /url: "#settings"
  - navigation [ref=e5]:
    - link "Settings" [ref=e6] [cursor=pointer]:
      - /url: "#settings"
  - main [ref=e7]:
    - heading "Account" [level=1] [ref=e8]
    - generic [ref=e9]:
      - text: Display name
      - textbox "Display name" [ref=e10]
    - button "Sign in" [ref=e11] [cursor=pointer]
    - button "Cancel" [ref=e12] [cursor=pointer]
    - link "Checkout" [ref=e13] [cursor=pointer]:
      - /url: "#checkout"
```