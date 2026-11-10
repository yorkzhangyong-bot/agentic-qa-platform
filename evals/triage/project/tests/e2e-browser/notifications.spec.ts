import { test, expect } from '@playwright/test';

test('shows toast', async ({ page }) => {
  await page.goto('/settings/notifications');
  await page.getByRole('button', { name: 'Send test notification' }).click();
  await expect(page.getByRole('status')).toHaveText('Test notification sent');
});

test("lists today's notifications", async ({ page, request }) => {
  await request.post('/api/test/notifications', { data: { count: 10 } });
  await page.goto('/notifications');
  await expect(page.getByRole('listitem')).toHaveCount(10);
});
