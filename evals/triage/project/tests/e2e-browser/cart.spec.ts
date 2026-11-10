import { test, expect } from '@playwright/test';

test('adds item to cart', async ({ page }) => {
  await page.goto('/products/espresso-machine');
  await expect(page.getByRole('button', { name: 'Add to cart' })).toBeVisible();
  await page.getByRole('button', { name: 'Add to cart' }).click();
  await expect(page.getByTestId('cart-count')).toHaveText('1');
});
