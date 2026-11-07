import { test, expect } from '@playwright/test';

test('exports a large report', async ({ page }) => {
  await page.goto('/reports');
  await page.getByRole('button', { name: 'Export' }).click();
  await expect(page.getByTestId('export-done')).toBeVisible({ timeout: 90000 });
});
