import { test, expect } from '@playwright/test';

test('edits the display name', async ({ page }) => {
  await page.goto('/');
  await page.getByLabel('Name', { exact: true }).fill('Ada');
});
