# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: e2e/settings.spec.ts >> opens the settings
- Location: tests/e2e/settings.spec.ts:3:5

# Error details

```
Error: locator.click: strict mode violation: getByText('Settings') resolved to 2 elements
```

# Page snapshot

```yaml
- generic [ref=e2]:
  - banner [ref=e3]:
    - link "Home" [ref=e4] [cursor=pointer]:
      - /url: /
    - link "Settings" [ref=e5] [cursor=pointer]:
      - /url: /settings
  - navigation [ref=e6]:
    - link "Settings" [ref=e7] [cursor=pointer]:
      - /url: /settings
```