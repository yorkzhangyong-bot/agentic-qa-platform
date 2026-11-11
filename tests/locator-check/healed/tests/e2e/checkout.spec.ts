import { test, expect } from '@playwright/test';

test('goes to checkout', async ({ page }) => {
  await page.goto('/');
  await page.getByRole('link', { name: 'Checkout' }).click();
});
