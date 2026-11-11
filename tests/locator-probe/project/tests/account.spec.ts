import { test, expect } from './fixtures';
import { AccountPage } from './pages/AccountPage';

test('opens the settings', async ({ page }) => {
  await page.getByRole('banner').getByRole('link', { name: 'Settings' }).click();
});

test('signs in', async ({ page }) => {
  await page.getByTestId('sign-in-button').click();
});

test('edits the display name', async ({ page }) => {
  await page.getByLabel('Display name').fill('Ada');
});

test('cancels through the page object', async ({ page }) => {
  await new AccountPage(page).cancel.click();
});

test('shows the checkout', async ({ page }) => {
  await expect(page.getByTestId('checkout')).toBeVisible();
});
