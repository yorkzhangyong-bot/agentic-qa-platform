import { test, expect } from '@playwright/test';

test('edits display name', async ({ page }) => {
  await page.goto('/profile');
  await page.getByLabel('Name', { exact: true }).fill('Ada Lovelace');
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByRole('status')).toHaveText('Profile updated');
});

test('saves the bio', async ({ page }) => {
  await page.goto('/profile');
  await page.getByLabel('Bio').fill('Tester of things');
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByRole('status')).toHaveText('Profile updated');
});
