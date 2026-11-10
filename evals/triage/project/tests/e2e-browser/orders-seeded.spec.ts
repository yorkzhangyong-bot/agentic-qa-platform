import { test, expect } from '@playwright/test';
import { seedOrders } from '../support/db';

test('shows seeded orders on the orders page', async ({ page }) => {
  await seedOrders([
    { id: 201, total: 15.0 },
    { id: 202, total: 42.5 },
  ]);
  await page.goto('/orders');
  await expect(page.getByTestId('order-number').filter({ hasText: /Order #20[12]/ })).toHaveCount(2);
});
