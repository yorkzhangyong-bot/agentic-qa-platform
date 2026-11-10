import { test, expect } from '@playwright/test';

test('validates email', async ({ page }) => {
  await page.goto('/signup');
  await page.getByLabel('Email').fill('abc');
  await page.getByLabel('Password').fill('S3cure-passphrase!');
  await page.getByRole('button', { name: 'Create account' }).click();
  const errorMsg = page.getByText('Enter a valid email address');
  await expect(errorMsg).toBeVisible();
});
