import { type Locator, type Page } from '@playwright/test';

export class ProfilePage {
  readonly bio: Locator;
  readonly save: Locator;

  constructor(page: Page) {
    this.bio = page.getByLabel('Bio');
    this.save = page.getByRole('button', {
      name: 'Save changes',
    });
  }
}
