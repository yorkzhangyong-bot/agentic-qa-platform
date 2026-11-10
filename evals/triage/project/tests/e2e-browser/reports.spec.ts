import { test } from '@playwright/test';

test('exports CSV', async ({ page }) => {
  await page.goto('/reports');
  const download = page.waitForEvent('download');
  await page.getByRole('button', { name: 'Export CSV' }).click();
  await (await download).saveAs('/tmp/export.csv');
});
