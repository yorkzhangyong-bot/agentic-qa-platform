import { test, expect } from '@playwright/test';

test('shows correct total', async ({ page, request }) => {
  await request.post('/api/test/cart', { data: { items: [{ sku: 'MUG-01', qty: 3, price: 10 }] } });
  await page.goto('/checkout');
  const total = await page.getByTestId('order-total').textContent();
  expect(total).toBe('$30.00');
});

test('places an order from the cart', async ({ page, request }) => {
  await request.post('/api/test/cart', {
    data: { items: [{ sku: 'MUG-01', qty: 1, price: 10 }, { sku: 'TEE-02', qty: 1, price: 20 }] },
  });
  await page.goto('/cart');
  await expect(page.getByRole('heading', { name: 'Your cart (2 items)' })).toBeVisible();
  await page.getByRole('button', { name: 'Place order' }).click();
  await expect(page).toHaveURL(/\/orders\/\d+$/);
});

test('confirms the order after payment', async ({ page, request }) => {
  await request.post('/api/test/cart', { data: { items: [{ sku: 'MUG-01', qty: 1, price: 10 }] } });
  await page.goto('/checkout');
  await page.getByRole('button', { name: 'Pay now' }).click();
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Order confirmed');
});
