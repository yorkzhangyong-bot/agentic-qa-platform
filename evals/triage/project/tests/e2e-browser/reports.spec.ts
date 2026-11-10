import { test, expect } from '@playwright/test';
import { readFile } from 'node:fs/promises';

test('exports CSV', async ({ page }) => {
  await page.goto('/reports');
  const download = page.waitForEvent('download');
  await page.getByRole('button', { name: 'Export CSV' }).click();
  await (await download).saveAs('/tmp/export.csv');
});

test('exports amounts with two decimals', async ({ page }) => {
  await page.goto('/reports');
  const download = page.waitForEvent('download');
  await page.getByRole('button', { name: 'Export CSV' }).click();
  const rows = (await readFile(await (await download).path(), 'utf-8')).trim().split('\n');
  expect(rows[0]).toBe('id,date,amount');
  expect(rows[3]).toBe('103,2026-01-31,12.50');
});
