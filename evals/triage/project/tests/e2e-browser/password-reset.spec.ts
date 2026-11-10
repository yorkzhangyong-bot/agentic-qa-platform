import { test, expect } from '@playwright/test';

test('sends a password reset email', async ({ page }) => {
  await page.goto('/login');
  await page.getByRole('link', { name: 'Forgot password?' }).click();
  await page.getByLabel('Email').fill('ada@example.com');
  const sent = page.waitForResponse((response) => response.url().endsWith('/api/password-reset'));
  await page.getByRole('button', { name: 'Send reset link' }).click();
  const response = await sent;
  expect(response.status(), `POST /api/password-reset returned ${response.status()}: ${await response.text()}`).toBe(202);
  await expect(page.getByRole('status')).toHaveText('Check your inbox');
});
