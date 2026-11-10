import { test, expect } from '@playwright/test';

test('loads charts', async ({ page }) => {
  await page.goto('/dashboard');
  const chart = page.getByTestId('revenue-chart');
  await expect(chart).toBeVisible();
});
