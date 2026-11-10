import { test, expect } from '@playwright/test';

test('searches products', async ({ page }) => {
  await page.goto('/');
  await page.locator('#search').fill('espresso');
  await page.keyboard.press('Enter');
  await expect(page.getByTestId('search-result')).not.toHaveCount(0);
});
