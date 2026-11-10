import { test, expect } from '@playwright/test';

test('streams reply', async ({ page }) => {
  await page.goto('/chat');
  await page.getByPlaceholder('Message').fill('Say hello');
  await page.keyboard.press('Enter');
  const reply = page.getByTestId('assistant-message').last();
  await expect(reply).toContainText('Hello');
});
