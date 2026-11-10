import { test, expect } from '@playwright/test';

test('lists orders newest first', async ({ page }) => {
  await page.goto('/orders');
  const firstRow = page.getByTestId('order-number').first();
  await expect(firstRow).toHaveText('Order #105');
});
