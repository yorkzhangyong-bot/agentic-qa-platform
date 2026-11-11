# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: e2e/delete.spec.ts >> deletes the draft
- Location: tests/e2e/delete.spec.ts:3:5

# Error details

```
Error: locator.click: Test timeout of 30000ms exceeded.
Call log:
  - waiting for getByRole('button', { name: 'Delete' })
```

# Page snapshot

```yaml
- main [ref=e2]:
  - heading "Draft" [level=1] [ref=e3]
  - button "Cancel" [ref=e4] [cursor=pointer]
```