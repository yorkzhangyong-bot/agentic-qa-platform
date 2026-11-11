import { test } from '@playwright/test';
import { ProfilePage } from '../pages/ProfilePage';

test('saves the bio', async ({ page }) => {
  const profile = new ProfilePage(page);
  await page.goto('/profile');
  await profile.bio.fill('Tester of things');
  await profile.save.click();
});
