import { test, expect } from '@playwright/test';

test('signs in', async ({ page }) => {
  await page.goto('/');
  await page.getByRole('button', { name: 'Log in' }).click();
});
