import { test, expect } from '@playwright/test';

test('keeps run after reload', async ({ page }) => {
  await page.goto('/runs');
  await page.getByRole('button', { name: 'New run' }).click();
  await page.getByLabel('Run name').fill('nightly-regression');
  await page.getByRole('button', { name: 'Create' }).click();
  const runRow = page.getByRole('row', { name: /nightly-regression/ });
  await expect(runRow).toBeVisible();
  await page.reload();
  await expect(runRow).toBeVisible();
});
