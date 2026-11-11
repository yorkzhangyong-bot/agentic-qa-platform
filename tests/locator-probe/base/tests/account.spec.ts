import { test, expect } from './fixtures';
import { AccountPage } from './pages/AccountPage';

test('opens the settings', async ({ page }) => {
  await page.getByText('Settings').click();
});

test('signs in', async ({ page }) => {
  await page.getByTestId('login-btn').click();
});

test('edits the display name', async ({ page }) => {
  await page.getByLabel('Name', { exact: true }).fill('Ada');
});

test('cancels through the page object', async ({ page }) => {
  await new AccountPage(page).cancel.click();
});

test('shows the checkout', async ({ page }) => {
  await expect(page.getByRole('button', { name: 'Checkout' })).toBeVisible();
});
