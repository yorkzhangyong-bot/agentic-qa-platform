import { test, expect } from '@playwright/test';

test('uploads a PDF', async ({ page }) => {
  await page.goto('/files');
  const response = page.waitForResponse((r) => r.url().endsWith('/api/files') && r.request().method() === 'POST');
  await page.getByLabel('Upload file').setInputFiles('tests/fixtures/sample.pdf');
  expect((await response).status()).toBe(201);
});
