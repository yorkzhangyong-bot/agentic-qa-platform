import { test, expect } from '@playwright/test';

test('shows the product price', async ({ page }) => {
  await page.goto('/products/ceramic-mug');
  await expect(page.getByRole('heading', { name: 'Ceramic mug' })).toBeVisible();
  await expect(page.getByTestId('price')).toHaveText('$12.00');
});
