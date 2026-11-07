import { test, expect } from '@playwright/test';

test.describe('Checkout', () => {
  test('applies a coupon', async ({ page }) => {
    await page.goto('/checkout');
    await page.getByTestId('coupon-input').fill('SAVE10');
    await page.getByTestId('apply-coupon').click();
    await expect(page.getByTestId('total')).toHaveText('$9.00');
    await expect(page.getByRole('status')).toBeVisible({ timeout: 10000 });
    expect(await page.title()).toBe('Checkout');
  });
});
