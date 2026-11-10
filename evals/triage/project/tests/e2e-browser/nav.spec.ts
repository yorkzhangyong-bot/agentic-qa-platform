import { test, expect } from '@playwright/test';

test('opens settings page', async ({ page }) => {
  await page.goto('/');
  await page.getByText('Settings').click();
  await expect(page).toHaveURL(/\/settings/);
});
