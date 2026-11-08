<!-- agentic-qa-defect: 38c26164626dba1dad27e3313a2c40abbbbb32e1 -->
# Wrong password shows no error (rejects a wrong password)

## Summary
Logging in with a wrong password shows no error message; the login page just stays as it is.

## Expected vs Actual
- **Expected:** an alert says that the email or password is wrong.
- **Actual:** no alert appears, and the user stays on /login.

## Steps to reproduce
1. Open the login page.
2. Enter a registered email address and a wrong password.
3. Press "Log in".

## Evidence
- Error: `Error: expect(locator).toBeVisible() failed for getByRole('alert') after 3 retries (session 4f1c2a9e-7b3d-4e8a-9c61-0d2f5b7a8e13)`
- Failing step: `tests/login.spec.ts:22`

## Triage reasoning
The form is found and submitted, so the test can drive the page; the expected alert never appears.

## Environment
- Commit: `0123456789abcdef0123456789abcdef01234567`
- App URL: https://staging.example.com
- Framework: playwright
- Engine / model: opencode / deepseek/deepseek-flash

## Links
- Workflow run: https://github.com/acme/shop/actions/runs/42
- Artifacts: `test-results` (JUnit reports), `triage` (failures.json, triage.json), `defects` (these reports)
