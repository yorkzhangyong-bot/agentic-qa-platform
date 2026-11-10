import { test, expect } from '@playwright/test';

test('pays with card', async ({ page }) => {
  await page.goto('/checkout');
  const card = page.frameLocator('iframe[title="Secure card payment input frame"]');
  await card.getByPlaceholder('Card number').fill('4242 4242 4242 4242');
  await card.getByPlaceholder('MM / YY').fill('12 / 34');
  await card.getByPlaceholder('CVC').fill('123');
  await page.getByRole('button', { name: 'Pay now' }).click();
  await expect(page.getByText('Payment successful')).toBeVisible();
});
