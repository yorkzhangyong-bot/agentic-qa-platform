import { test as base, expect } from '@playwright/test';

const ACCOUNT = `
<header><a href="#home">Home</a> <a href="#settings">Settings</a></header>
<nav><a href="#settings">Settings</a></nav>
<main>
  <h1>Account</h1>
  <label>Display name <input name="display"></label>
  <button data-testid="sign-in-button">Sign in</button>
  <button>Cancel</button>
  <a href="#checkout" data-testid="checkout">Checkout</a>
</main>`;

// The project's own fixture, as consumer projects have: every test starts on the account page.
export const test = base.extend<{ account: void }>({
  account: [async ({ page }, use) => {
    await page.setContent(ACCOUNT);
    await use();
  }, { auto: true }],
});

export { expect };
