import { test, expect } from '@playwright/test';

test('logs in with valid credentials', async ({ page }) => {
  await page.goto('/login');
  await page.getByLabel('Email').fill(process.env.TEST_USER_EMAIL ?? 'qa@example.com');
  await page.getByLabel('Password').fill(process.env.TEST_USER_PASSWORD ?? 'correct-horse-battery');
  await page.getByTestId('login-btn').click();
  await expect(page).toHaveURL(/\/dashboard/);
});

test('rejects wrong password', async ({ page }) => {
  await page.goto('/login');
  await page.getByLabel('Email').fill('qa@example.com');
  await page.getByLabel('Password').fill('not-the-password');
  await page.getByTestId('login-btn').click();
  await expect(page).toHaveURL(/login/);
});
