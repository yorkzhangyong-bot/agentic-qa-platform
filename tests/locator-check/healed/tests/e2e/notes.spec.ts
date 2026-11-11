import { test, expect } from '@playwright/test';

test('opens the notes', async ({ page }) => {
  await page.goto('/');
  // open the notes page
  await page.getByRole('link', { name: 'Notes' }).click();
});
