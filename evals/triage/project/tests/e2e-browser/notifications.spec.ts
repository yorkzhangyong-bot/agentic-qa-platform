import { test, expect } from '@playwright/test';

test('shows toast', async ({ page }) => {
  await page.goto('/settings/notifications');
  await page.getByRole('button', { name: 'Send test notification' }).click();
  await expect(page.getByRole('status')).toHaveText('Test notification sent');
});
