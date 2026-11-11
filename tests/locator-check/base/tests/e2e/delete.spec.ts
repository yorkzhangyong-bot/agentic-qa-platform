import { test, expect } from '@playwright/test';

test('deletes the draft', async ({ page }) => {
  await page.goto('/');
  await page.getByRole('button', { name: 'Delete' }).click();
});
