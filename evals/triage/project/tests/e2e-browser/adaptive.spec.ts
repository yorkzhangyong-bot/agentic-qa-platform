import { test, expect } from '@playwright/test';

test('runs adaptive attack', async ({ page }) => {
  await page.goto('/attacks/adaptive');
  await page.getByLabel('Target model').selectOption('demo-chatbot');
  const created = page.waitForResponse((r) => r.url().endsWith('/api/runs') && r.request().method() === 'POST');
  await page.getByRole('button', { name: 'Start attack' }).click();
  expect((await created).status()).toBe(201);
});
