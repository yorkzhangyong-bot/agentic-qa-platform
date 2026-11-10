import { test, expect } from '@playwright/test';

test('any test', async ({ page }) => {
  await page.goto('/');
  await expect(page).toHaveTitle(/.+/);
});
