import { test, expect } from '@playwright/test';

test('shows correct total', async ({ page, request }) => {
  await request.post('/api/test/cart', { data: { items: [{ sku: 'MUG-01', qty: 3, price: 10 }] } });
  await page.goto('/checkout');
  const total = await page.getByTestId('order-total').textContent();
  expect(total).toBe('$30.00');
});
