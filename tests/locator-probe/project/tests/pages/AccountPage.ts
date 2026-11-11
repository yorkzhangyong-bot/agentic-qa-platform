import { type Locator, type Page } from '@playwright/test';

export class AccountPage {
  readonly cancel: Locator;

  constructor(page: Page) {
    this.cancel = page.getByRole('button', { name: 'Cancel' });
  }
}
