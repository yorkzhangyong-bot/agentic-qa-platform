import { test, expect } from '@playwright/test';

test('paginates', async ({ page }) => {
  await page.goto('/runs');
  await page.getByRole('button', { name: 'Next page' }).click();
  await expect(page.getByText('Page 2 of 5')).toBeVisible();
});
