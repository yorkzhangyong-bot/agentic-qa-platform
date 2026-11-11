# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: e2e/profile-save.spec.ts >> saves the bio
- Location: tests/e2e/profile-save.spec.ts:3:5

# Error details

```
Error: locator.click: strict mode violation: getByRole('button', { name: 'Save' }) resolved to 2 elements
```

# Page snapshot

```yaml
- main [ref=e2]:
  - textbox "Bio" [ref=e3]: Tester of things
  - button "Save changes" [ref=e4] [cursor=pointer]
```