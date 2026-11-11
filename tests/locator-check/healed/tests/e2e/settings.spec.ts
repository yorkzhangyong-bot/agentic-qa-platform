import { test, expect } from '@playwright/test';

test('opens the settings', async ({ page }) => {
  await page.goto('/');
  await page.getByRole('banner').getByRole('link', { name: 'Settings' }).click();
});
