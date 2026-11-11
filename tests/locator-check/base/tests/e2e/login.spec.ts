import { test, expect } from '@playwright/test';

test('logs in', async ({ page }) => {
  await page.goto('/');
  await page.getByTestId('login-btn').click();
});
