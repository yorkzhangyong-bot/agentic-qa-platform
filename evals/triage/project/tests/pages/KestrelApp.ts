import { type Locator, type Page, expect } from '@playwright/test';

const PERMISSION_LABEL = 'I own this agent or have written permission to test it';

export interface SelectableTarget {
  name: string;
  url: string;
}

/**
 * Kestrel's single screen. Streamlit renders the selectboxes as BaseWeb comboboxes, so targets, families and
 * prompts are selected by their visible option label rather than with selectOption.
 */
export class KestrelApp {
  readonly page: Page;
  readonly targetSelect: Locator;
  readonly modeGroup: Locator;
  readonly attackFamily: Locator;
  readonly promptSelect: Locator;
  readonly openRunSelect: Locator;
  readonly runButton: Locator;
  readonly captions: Locator;
  readonly texts: Locator;
  readonly adaptiveCaption: Locator;
  readonly displayName: Locator;
  readonly endpointUrl: Locator;
  readonly bodyTemplate: Locator;
  readonly responsePath: Locator;
  readonly permissionCheckbox: Locator;
  readonly addCanaryButton: Locator;
  readonly testConnectionButton: Locator;
  readonly saveTargetButton: Locator;
  readonly deleteTargetButton: Locator;
  readonly confirmDeleteButton: Locator;
  readonly alerts: Locator;
  readonly codeBlocks: Locator;

  constructor(readonly page: Page) {
    this.targetSelect = page.getByRole('combobox', { name: 'Target', exact: true });
    // Streamlit renders two "Mode" radio groups with the same accessible name: the Attack panel's and the
    // Experiments panel's. Only the Attack one is keyed `attack_mode`, and Streamlit puts that key on the
    // widget container as `st-key-attack_mode` (no data-testid is emitted for it), so this is the one stable
    // way to scope the radio group at the top of the page.
    this.modeGroup = page.locator('.st-key-attack_mode');
    this.attackFamily = page.getByRole('combobox', { name: 'Attack family', exact: true });
    this.promptSelect = page.getByRole('combobox', { name: 'Prompt', exact: true });
    this.openRunSelect = page.getByRole('combobox', { name: 'Open a run', exact: true });
    this.runButton = page.getByRole('button', { name: 'Run attack', exact: true });
    this.captions = page.getByTestId('stCaptionContainer');
    this.texts = page.getByTestId('stText');
    this.adaptiveCaption = this.captions.filter({ hasText: 'Adaptive: attacker' });
    this.displayName = page.getByRole('textbox', { name: 'Display name', exact: true });
    this.endpointUrl = page.getByRole('textbox', { name: 'Endpoint URL', exact: true });
    this.bodyTemplate = page.getByRole('textbox', { name: 'Request body template', exact: true });
    this.responsePath = page.getByRole('textbox', { name: 'Response path', exact: true });
    this.permissionCheckbox = page.getByRole('checkbox', { name: PERMISSION_LABEL, exact: true });
    this.addCanaryButton = page.getByRole('button', { name: 'Add canary', exact: true });
    this.testConnectionButton = page.getByRole('button', { name: 'Test connection', exact: true });
    this.saveTargetButton = page.getByRole('button', { name: 'Save target', exact: true });
    this.deleteTargetButton = page.getByRole('button', { name: 'Delete target', exact: true });
    this.confirmDeleteButton = page.getByRole('button', { name: 'Confirm delete', exact: true });
    this.alerts = page.getByTestId('stAlert');
    // stCode wraps a copy toolbar as well as the code; the plain-text code itself is the <pre><code> node.
    this.codeBlocks = page.locator('pre code');
  }

  get canaryInputs(): Locator {
    return this.page.getByRole('textbox', { name: 'Canary', exact: true });
  }

  /** The "Turn N · attacker" captions that head each turn of an adaptive conversation. */
  get turnCaptions(): Locator {
    return this.captions.filter({ hasText: /^Turn \d+ · attacker$/ });
  }

  /** The "agent" caption that heads each stored target reply in an adaptive conversation. */
  get agentCaptions(): Locator {
    return this.captions.filter({ hasText: /^agent$/ });
  }

  async selectMode(mode: 'Single-turn' | 'Adaptive'): Promise<void> {
    await this.modeGroup.getByText(mode, { exact: true }).click();
    await expect(this.modeGroup.getByRole('radio', { name: mode })).toBeChecked();
  }

  async goto(): Promise<void> {
    await this.page.goto('/');
    await expect(this.runButton).toBeVisible();
  }

  async selectTarget(target: SelectableTarget): Promise<void> {
    await this.openSelect(this.targetSelect);
    await this.page.getByRole('option', { name: `${target.name} · ${target.url}`, exact: true }).click();
    // Streamlit loads the target's form on the next rerun; the display name is set by that rerun.
    await expect(this.targetSelect).toHaveValue(`${target.name} · ${target.url}`);
    await expect(this.displayName).toHaveValue(target.name);
  }

  async selectFamily(label: string): Promise<void> {
    await this.openSelect(this.attackFamily);
    await this.page.getByRole('option', { name: label, exact: true }).click();
    await expect(this.attackFamily).toHaveValue(label);
    await expect(this.promptSelect).toBeVisible();
  }

  async selectPrompt(title: string): Promise<void> {
    await this.openSelect(this.promptSelect);
    await this.page.getByRole('option', { name: title, exact: true }).click();
    await expect(this.promptSelect).toHaveValue(title);
    await expect(this.codeBlocks.first()).toBeVisible();
  }

  async selectRun(label: string): Promise<void> {
    await this.openSelect(this.openRunSelect);
    await this.page.getByRole('option', { name: label, exact: true }).click();
    await expect(this.openRunSelect).toHaveValue(label);
    await expect(this.alerts.first()).toBeVisible();
  }

  async targetOptions(): Promise<string[]> {
    return this.optionLabels(this.targetSelect);
  }

  async openRunOptions(): Promise<string[]> {
    return this.optionLabels(this.openRunSelect);
  }

  async promptOptions(): Promise<string[]> {
    return this.optionLabels(this.promptSelect);
  }

  /**
   * Open a BaseWeb selectbox. Clicking is enough for the pickers at the top of the page, while the Runs picker
   * only expands once it receives a key, so press ArrowDown afterwards; the list opens in both cases and the
   * active option is only committed by a click or Enter.
   */
  private async openSelect(select: Locator): Promise<void> {
    await select.click();
    await select.press('ArrowDown');
    await expect(this.page.getByRole('option').first()).toBeVisible();
  }

  /** Open a BaseWeb selectbox, read the visible option labels, then close it again. */
  private async optionLabels(select: Locator): Promise<string[]> {
    await this.openSelect(select);
    const labels = await this.page.getByRole('option').allInnerTexts();
    await this.page.keyboard.press('Escape');
    await expect(this.page.getByRole('listbox')).toHaveCount(0);
    return labels;
  }

  async runAttack(): Promise<void> {
    await this.runButton.click();
  }

  /** Wait until Streamlit has finished the run: the result alert is up and Run is usable again. */
  async waitForRunToFinish(timeout = 120_000): Promise<void> {
    await expect(this.alerts.first()).toBeVisible({ timeout });
    await expect(this.runButton).toBeEnabled({ timeout });
  }

  async alertWithText(text: string | RegExp): Promise<Locator> {
    return this.alerts.filter({ hasText: text });
  }

  async addCanary(value: string): Promise<void> {
    const before = await this.canaryInputs.count();
    await this.addCanaryButton.click();
    await expect(this.canaryInputs).toHaveCount(before + 1);
    // All canary rows share the same accessible label "Canary", so position is the only way to pick the new row.
    const input = this.canaryInputs.nth(before);
    await input.fill(value);
    await input.blur();
  }

  async canaryValues(): Promise<string[]> {
    return this.canaryInputs.evaluateAll((inputs) => inputs.map((input) => (input as HTMLInputElement).value));
  }

  /** The native checkbox is covered by its label, so toggle it through the label and verify the state. */
  async setPermission(checked: boolean): Promise<void> {
    if ((await this.permissionCheckbox.isChecked()) !== checked) {
      await this.page.getByTestId('stSidebar').getByText(PERMISSION_LABEL, { exact: true }).click();
    }
    await expect(this.permissionCheckbox).toBeChecked({ checked });
  }

  async changeEndpoint(url: string): Promise<void> {
    await this.endpointUrl.fill(url);
    await this.endpointUrl.press('Tab');
  }

  async askToDeleteTarget(): Promise<void> {
    await this.deleteTargetButton.click();
    await expect(this.page.getByText('Delete this target and its stored auth headers?', { exact: true })).toBeVisible();
  }
}
