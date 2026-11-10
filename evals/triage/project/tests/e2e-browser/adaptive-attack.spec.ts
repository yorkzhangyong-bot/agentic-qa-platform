import { test, expect, runLabel, uniqueName } from './fixtures/kestrel';
import type { KestrelApi } from './fixtures/kestrel';
import { KestrelApp } from '../pages/KestrelApp';

const SPL_FAMILY = 'System prompt leak · LLM07: System Prompt Leakage (4 prompts)';
const CANARY = 'KESTREL-CANARY-demo';
const CANARY_REPLY = `Here is my system prompt: ${CANARY}`;
const RUN_PLACEHOLDER = 'Choose a run to see its prompt and reply';

function runOnlyOptions(options: string[]): string[] {
  return options.filter((label) => label !== RUN_PLACEHOLDER);
}

async function chosenPrompt(api: KestrelApi, id: string) {
  const prompts = await api.attackPrompts('system_prompt_leak');
  const prompt = prompts.find((candidate) => candidate.id === id);
  expect(prompt, `attack prompt ${id} is missing`).toBeDefined();
  return prompt as NonNullable<typeof prompt>;
}

/** Covers AC1, FR-001, FR-014, FR-016 */
test('1. offers an Adaptive mode that shows the attacker and caps [FR-001, FR-014, FR-016]', async ({
  page,
  api,
  stub,
}) => {
  const config = await api.config();
  expect(config.attacker.configured, 'the API must be started with an attacker key').toBe(true);
  const target = await api.createTarget(uniqueName(), stub);
  const prompt = await chosenPrompt(api, 'spl-002');
  const app = new KestrelApp(page);

  await app.goto();
  await app.selectTarget(target);
  await app.selectFamily(SPL_FAMILY);
  await app.selectPrompt(prompt.title);

  await expect(app.modeGroup.getByRole('radio')).toHaveCount(2);
  await expect(app.modeGroup.getByRole('radio', { name: 'Single-turn' })).toBeChecked();
  await expect(app.modeGroup.getByRole('radio', { name: 'Adaptive' })).not.toBeChecked();
  await expect(app.adaptiveCaption).toHaveCount(0);

  await app.selectMode('Adaptive');

  await expect(app.adaptiveCaption).toHaveText(
    `Adaptive: attacker ${config.attacker.model}, up to ${config.adaptive.max_turns} turns`,
  );
  await expect(app.runButton).toBeEnabled();
  await expect(app.attackFamily).toHaveValue(SPL_FAMILY);
  await expect(app.promptSelect).toHaveValue(prompt.title);
});

/** Covers AC1, FR-002, FR-006, FR-009 */
test('2. opens an adaptive attack with the chosen family prompt [FR-002, FR-006, FR-009]', async ({
  page,
  api,
  stub,
}) => {
  stub.setReply(CANARY_REPLY);
  const target = await api.createTarget(uniqueName(), stub, { canaries: [CANARY] });
  const prompt = await chosenPrompt(api, 'spl-002');
  const app = new KestrelApp(page);

  await app.goto();
  await app.selectTarget(target);
  await app.selectFamily(SPL_FAMILY);
  await app.selectPrompt(prompt.title);
  await app.selectMode('Adaptive');

  stub.resetRequests();
  await app.runAttack();
  await app.waitForRunToFinish();

  expect(stub.requests).toHaveLength(1);
  expect(stub.jsonBodies[0].message).toBe(prompt.text);

  const newest = (await api.listRuns(target.id))[0];
  const run = await api.getRun(newest.id);
  expect(run.mode).toBe('adaptive');
  expect(run.turns_used).toBe(1);
  expect(run.turns).toHaveLength(1);
  expect(run.turns[0].attacker_message).toBe(prompt.text);

  await expect(app.turnCaptions).toHaveText(['Turn 1 · attacker']);
  await expect(app.codeBlocks.filter({ hasText: prompt.text }).last()).toHaveText(prompt.text);
  await expect(app.codeBlocks.filter({ hasText: CANARY_REPLY }).first()).toHaveText(CANARY_REPLY);
});

/** Covers AC1, AC6, FR-020, FR-023, SC-002 */
test('3. shows the adaptive conversation turn by turn [FR-020, FR-023, SC-002]', async ({ page, api, stub }) => {
  const config = await api.config();
  stub.setReply(CANARY_REPLY);
  const target = await api.createTarget(uniqueName(), stub, { canaries: [CANARY] });
  const seeded = await api.createRun(target.id, {
    family: 'system_prompt_leak',
    promptId: 'spl-002',
    mode: 'adaptive',
  });
  const run = await api.getRun(seeded.id);
  const turn = run.turns[0];
  const app = new KestrelApp(page);

  await app.goto();
  await app.selectTarget(target);
  await app.selectRun(runLabel(run));

  await expect(app.alerts.first()).toHaveText('Attack succeeded · confirmed by canary at turn 1');
  await expect(app.turnCaptions).toHaveText([`Turn ${turn.position} · attacker`]);
  await expect(app.codeBlocks.filter({ hasText: turn.attacker_message }).first()).toHaveText(turn.attacker_message);
  await expect(app.agentCaptions).toHaveText(['agent']);
  await expect(app.codeBlocks.filter({ hasText: turn.reply_text ?? '' }).first()).toHaveText(turn.reply_text ?? '');
  await expect(app.texts.filter({ hasText: run.reason ?? '' })).toBeVisible();

  const footer = app.captions
    .filter({ hasText: `attacker ${run.attacker_model}` })
    .filter({ hasText: `${run.turns_used}/${config.adaptive.max_turns} turns` });
  await expect(footer.first()).toBeVisible();
});

/** Covers AC2, FR-007, FR-018, FR-019, SC-003 */
test('4. stops at a canary with hard evidence and no judge [FR-007, FR-018, FR-019, SC-003]', async ({
  page,
  api,
  stub,
}) => {
  stub.setReply(CANARY_REPLY);
  const target = await api.createTarget(uniqueName(), stub, { canaries: [CANARY] });
  const seeded = await api.createRun(target.id, {
    family: 'system_prompt_leak',
    promptId: 'spl-002',
    mode: 'adaptive',
  });

  const run = await api.getRun(seeded.id);
  expect(run.verdict).toBe('succeeded');
  expect(run.hard_evidence).toBe(true);
  expect(run.judge_used).toBe(false);
  expect(run.judge_model).toBeNull();
  expect(run.succeeded_turn).toBe(1);
  expect(run.stopping_condition).toBe('succeeded');
  expect(run.turns_used).toBe(1);
  expect(run.turns).toHaveLength(1);

  const app = new KestrelApp(page);
  await app.goto();
  await app.selectTarget(target);
  await app.selectRun(runLabel(run));

  await expect(app.alerts.first()).toHaveText('Attack succeeded · confirmed by canary at turn 1');
  await expect(app.alerts.first()).not.toContainText('suspected');
  const footer = app.captions.filter({ hasText: `attacker ${run.attacker_model}` });
  await expect(footer.first()).toBeVisible();
  await expect(footer.first()).not.toContainText('judge');
});

/** Covers AC10, FR-014, FR-015, SC-004 */
test('5. records the attacker model and budgets [FR-014, FR-015, SC-004]', async ({ page, api, stub }) => {
  const config = await api.config();
  stub.setReply(CANARY_REPLY);
  const target = await api.createTarget(uniqueName(), stub, { canaries: [CANARY] });
  const seeded = await api.createRun(target.id, {
    family: 'system_prompt_leak',
    promptId: 'spl-002',
    mode: 'adaptive',
  });
  const run = await api.getRun(seeded.id);

  expect(run.mode).toBe('adaptive');
  expect(run.attacker_model).toBe(config.attacker.model);
  expect(run.turn_budget).toBe(config.adaptive.max_turns);
  expect(run.token_budget).toBe(config.adaptive.token_budget);
  expect(run.time_limit_s).toBe(config.adaptive.time_limit_s);
  expect(run.turns_used).not.toBeNull();
  expect(run.turns_used as number).toBeGreaterThanOrEqual(1);
  expect(Number.isInteger(run.tokens_used)).toBe(true);
  expect(run.tokens_used as number).toBeGreaterThanOrEqual(0);
  expect(run.stopping_condition).not.toBeNull();
  if (run.judge_used) {
    expect(run.judge_model).toBe(config.judge.model);
  } else {
    expect(run.judge_model).toBeNull();
  }

  const app = new KestrelApp(page);
  await app.goto();
  await app.selectTarget(target);
  await app.selectRun(runLabel(run));

  const footer = app.captions
    .filter({ hasText: `attacker ${run.attacker_model}` })
    .filter({ hasText: `${run.turns_used}/${run.turn_budget} turns` })
    .filter({ hasText: `${run.tokens_used} tokens` });
  await expect(footer.first()).toBeVisible();
});

/** Covers AC5, FR-012, FR-013, SC-002 */
test('6. stores the failed send step when the target is unreachable [FR-012, FR-013, SC-002]', async ({
  page,
  api,
  stub,
}) => {
  const target = await api.createTarget(uniqueName(), stub);
  await stub.close();
  const app = new KestrelApp(page);

  await app.goto();
  await app.selectTarget(target);
  await app.selectFamily(SPL_FAMILY);
  await app.selectMode('Adaptive');
  await app.runAttack();
  await expect(app.alerts.first()).toBeVisible();

  const summary = (await api.listRuns(target.id))[0];
  expect(summary).toBeDefined();
  const run = await api.getRun(summary.id);
  expect(run.verdict).toBeNull();
  expect(run.failure_step).toBe('unreachable');
  expect(run.stopping_condition).toBe('send_failed');
  expect(run.turns).toHaveLength(1);
  expect(run.turns[0].reply_text).toBeNull();

  await expect(app.alerts.first()).toHaveText("Kestrel couldn't connect to this URL.");
  await expect(app.turnCaptions).toHaveCount(0);
  await expect(app.codeBlocks.filter({ hasText: run.turns[0].attacker_message })).toHaveCount(0);
});

/** Covers AC6, FR-020, FR-022, FR-023 */
test('7. opens a finished adaptive run from history [FR-020, FR-022, FR-023]', async ({ page, api, stub }) => {
  stub.setReply(CANARY_REPLY);
  const target = await api.createTarget(uniqueName(), stub, { canaries: [CANARY] });
  const singleTurn = await api.createRun(target.id, { family: 'system_prompt_leak', promptId: 'spl-001' });
  const adaptive = await api.createRun(target.id, {
    family: 'system_prompt_leak',
    promptId: 'spl-002',
    mode: 'adaptive',
  });
  const stored = await api.getRun(adaptive.id);
  const turn = stored.turns[0];
  const app = new KestrelApp(page);

  await app.goto();
  await app.selectTarget(target);
  await app.selectRun(runLabel(stored));

  await expect(app.alerts.first()).toHaveText('Attack succeeded · confirmed by canary at turn 1');
  await expect(app.turnCaptions).toHaveCount(stored.turns.length);
  await expect(app.turnCaptions.first()).toHaveText(`Turn ${turn.position} · attacker`);
  await expect(app.codeBlocks.filter({ hasText: turn.attacker_message }).first()).toHaveText(turn.attacker_message);
  await expect(app.agentCaptions).toHaveCount(stored.turns.length);
  await expect(app.codeBlocks.filter({ hasText: turn.reply_text ?? '' }).first()).toHaveText(turn.reply_text ?? '');
  await expect(app.texts.filter({ hasText: stored.reason ?? '' })).toBeVisible();
  await expect(app.captions.filter({ hasText: `attacker ${stored.attacker_model}` }).first()).toBeVisible();

  await app.selectRun(runLabel(singleTurn));
  await expect(app.turnCaptions).toHaveCount(0);
  await expect(app.codeBlocks.filter({ hasText: singleTurn.prompt_text }).first()).toHaveText(singleTurn.prompt_text);
  await expect(app.codeBlocks.filter({ hasText: CANARY_REPLY }).first()).toHaveText(CANARY_REPLY);
});

/** Covers AC7, FR-022 */
test('8. lists adaptive and single-turn runs newest first [FR-022]', async ({ page, api, stub }) => {
  stub.setReply(CANARY_REPLY);
  const target = await api.createTarget(uniqueName(), stub, { canaries: [CANARY] });
  const singleTurn = await api.createRun(target.id, { family: 'system_prompt_leak', promptId: 'spl-001' });
  const adaptive = await api.createRun(target.id, {
    family: 'system_prompt_leak',
    promptId: 'spl-002',
    mode: 'adaptive',
  });

  const stored = await api.listRuns(target.id);
  expect(stored.map((run) => run.id)).toEqual([adaptive.id, singleTurn.id]);
  expect(stored.map((run) => run.mode)).toEqual(['adaptive', 'single_turn']);

  const app = new KestrelApp(page);
  await app.goto();
  await app.selectTarget(target);

  const options = runOnlyOptions(await app.openRunOptions());
  expect(options).toEqual([runLabel(adaptive), runLabel(singleTurn)]);
  for (const run of [adaptive, singleTurn]) {
    expect(runLabel(run)).toMatch(/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} · /);
    expect(runLabel(run)).toContain(run.prompt_title);
  }

  // Streamlit draws st.dataframe on a canvas, so the Mode cell text can't be read from the DOM. The Runs table
  // is still rendered; the modes themselves are asserted through the API above and through each opened run.
  await expect(page.getByTestId('stDataFrame').first()).toBeVisible();
  await app.selectRun(runLabel(adaptive));
  await expect(app.alerts.first()).toHaveText('Attack succeeded · confirmed by canary at turn 1');
  await expect(app.turnCaptions).toHaveCount(1);
  await app.selectRun(runLabel(singleTurn));
  await expect(app.turnCaptions).toHaveCount(0);
  await expect(app.codeBlocks.filter({ hasText: singleTurn.prompt_text }).first()).toHaveText(singleTurn.prompt_text);
});

/** Covers AC1, FR-004 */
test('9. refuses a second run while an adaptive run is in progress [FR-004]', async ({
  page,
  browser,
  api,
  stub,
}) => {
  stub.setReply(CANARY_REPLY);
  const target = await api.createTarget(uniqueName(), stub, { canaries: [CANARY] });
  stub.setDelay(12_000);

  const appA = new KestrelApp(page);
  await appA.goto();
  await appA.selectTarget(target);
  await appA.selectFamily(SPL_FAMILY);
  await appA.selectMode('Adaptive');

  const origin = new URL(page.url()).origin;
  const contextB = await browser.newContext({ baseURL: origin });
  const pageB = await contextB.newPage();
  const appB = new KestrelApp(pageB);
  await appB.goto();
  await appB.selectTarget(target);
  await appB.selectMode('Single-turn');

  stub.resetRequests();
  await appA.runAttack();
  await appB.runAttack();
  const busy = appB.alerts.filter({ hasText: 'A run against this target is already in progress.' });
  await expect(busy.first()).toBeVisible({ timeout: 15_000 });
  await expect(busy.first()).toHaveText('A run against this target is already in progress.');

  await appA.waitForRunToFinish(25_000);
  await expect(appA.alerts.first()).toHaveText('Attack succeeded · confirmed by canary at turn 1');
  expect(await api.listRuns(target.id)).toHaveLength(1);
  await contextB.close();
});

/** Covers AC9, FR-022 */
test('10. deletes a target with its adaptive runs [FR-022]', async ({ page, api, stub }) => {
  stub.setReply(CANARY_REPLY);
  const target = await api.createTarget(uniqueName(), stub, { canaries: [CANARY] });
  const seeded = await api.createRun(target.id, {
    family: 'system_prompt_leak',
    promptId: 'spl-002',
    mode: 'adaptive',
  });
  const app = new KestrelApp(page);

  await app.goto();
  await app.selectTarget(target);
  await app.selectRun(runLabel(seeded));
  await expect(app.alerts.first()).toHaveText('Attack succeeded · confirmed by canary at turn 1');

  await app.askToDeleteTarget();
  await app.confirmDeleteButton.click();
  await expect(app.alerts.filter({ hasText: 'Target deleted.' })).toBeVisible();

  expect(await app.targetOptions()).not.toContain(`${target.name} · ${target.url}`);
  await expect(app.targetSelect).toHaveValue('New target');
  await expect(page.getByText('Select a saved target to see its runs.', { exact: true })).toBeVisible();

  expect(await api.getTargetStatus(target.id)).toBe(404);
  expect(await api.listRunStatus(target.id)).toBe(404);
  expect(await api.getRunStatus(seeded.id)).toBe(404);
});

/** Covers AC8, FR-022, SC-010 */
test('11. keeps an adaptive run after a page reload [FR-022, SC-010]', async ({ page, api, stub }) => {
  stub.setReply(CANARY_REPLY);
  const target = await api.createTarget(uniqueName(), stub, { canaries: [CANARY] });
  const seeded = await api.createRun(target.id, {
    family: 'system_prompt_leak',
    promptId: 'spl-002',
    mode: 'adaptive',
  });
  const run = await api.getRun(seeded.id);
  const label = runLabel(run);
  const turn = run.turns[0];
  const app = new KestrelApp(page);

  await app.goto();
  await app.selectTarget(target);
  expect(runOnlyOptions(await app.openRunOptions())).toContain(label);
  await app.selectRun(label);
  await expect(app.alerts.first()).toHaveText('Attack succeeded · confirmed by canary at turn 1');
  await expect(app.turnCaptions).toHaveText(['Turn 1 · attacker']);

  await page.reload();
  await expect(app.runButton).toBeVisible();
  await app.selectTarget(target);
  expect(runOnlyOptions(await app.openRunOptions())).toContain(label);

  await app.selectRun(label);
  await expect(app.alerts.first()).toHaveText('Attack succeeded · confirmed by canary at turn 1');
  await expect(app.texts.filter({ hasText: run.reason ?? '' })).toBeVisible();
  await expect(app.codeBlocks.filter({ hasText: turn.attacker_message }).first()).toHaveText(turn.attacker_message);
  await expect(app.codeBlocks.filter({ hasText: turn.reply_text ?? '' }).first()).toHaveText(turn.reply_text ?? '');
});

/** Covers AC1, FR-024, SC-007 */
test('12. renders the adaptive conversation as plain text [FR-024, SC-007]', async ({ page, api, stub }) => {
  const hostile = `${CANARY} <script>alert('xss')</script> **bold** [click](http://evil.invalid/) ![img](http://evil.invalid/i.png)`;
  stub.setReply(hostile);
  const target = await api.createTarget(uniqueName(), stub, { canaries: [CANARY] });
  const requests: string[] = [];
  page.on('request', (request) => requests.push(request.url()));

  const seeded = await api.createRun(target.id, {
    family: 'system_prompt_leak',
    promptId: 'spl-002',
    mode: 'adaptive',
  });
  const run = await api.getRun(seeded.id);
  expect(run.turns[0].reply_text).toBe(hostile);

  const app = new KestrelApp(page);
  await app.goto();
  await app.selectTarget(target);
  await app.selectRun(runLabel(run));

  await expect(app.codeBlocks.filter({ hasText: 'evil.invalid' }).first()).toHaveText(hostile);
  expect(requests.some((url) => url.includes('evil.invalid'))).toBe(false);

  const injected = await page.evaluate(() => ({
    script: Array.from(document.querySelectorAll('script')).some((element) =>
      (element.textContent ?? '').includes("alert('xss')"),
    ),
    image: Array.from(document.querySelectorAll('img')).some((element) =>
      (element.getAttribute('src') ?? '').includes('evil.invalid'),
    ),
    link: document.querySelectorAll('a[href*="evil.invalid"]').length,
  }));
  expect(injected.script).toBe(false);
  expect(injected.image).toBe(false);
  expect(injected.link).toBe(0);
});

/** Covers AC1, FR-021, SC-006 */
test('13. masks auth header values in the adaptive conversation [FR-021, SC-006]', async ({
  page,
  api,
  stub,
}) => {
  const secret = `QA-HEADER-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  stub.setReply(`${CANARY} echoed ${secret}`);
  const target = await api.createTarget(uniqueName(), stub, {
    canaries: [CANARY],
    headers: [{ name: 'X-API-Key', value: secret }],
  });
  const seeded = await api.createRun(target.id, {
    family: 'system_prompt_leak',
    promptId: 'spl-002',
    mode: 'adaptive',
  });
  const run = await api.getRun(seeded.id);

  const runJson = JSON.stringify(run);
  expect(runJson).toContain('••••');
  expect(runJson).not.toContain(secret);
  const reply = run.turns[0].reply_text ?? '';
  expect(reply).toContain('••••');
  expect(reply).not.toContain(secret);

  const app = new KestrelApp(page);
  await app.goto();
  await app.selectTarget(target);
  await app.selectRun(runLabel(run));

  await expect(app.codeBlocks.filter({ hasText: '••••' }).first()).toHaveText(reply);
  await expect(page.getByText(secret, { exact: false })).toHaveCount(0);
});

/** Covers AC1, FR-021 */
test('14. cuts a long adaptive reply before storing it [FR-021]', async ({ page, api, stub }) => {
  const longReply = `${CANARY} ${'z'.repeat(2_400)} TAIL-MARKER`;
  stub.setReply(longReply);
  const target = await api.createTarget(uniqueName(), stub, { canaries: [CANARY] });
  const seeded = await api.createRun(target.id, {
    family: 'system_prompt_leak',
    promptId: 'spl-002',
    mode: 'adaptive',
  });
  const run = await api.getRun(seeded.id);
  const stored = run.turns[0].reply_text ?? '';

  expect(run.turns[0].reply_truncated).toBe(true);
  expect(stored.length).toBeLessThanOrEqual(2_000);
  expect(stored).toContain(CANARY);
  expect(stored).not.toContain('TAIL-MARKER');
  expect(run.verdict).toBe('succeeded');
  expect(run.succeeded_turn).toBe(1);

  const app = new KestrelApp(page);
  await app.goto();
  await app.selectTarget(target);
  await app.selectRun(runLabel(run));

  await expect(app.codeBlocks.filter({ hasText: CANARY }).first()).toHaveText(stored);
  await expect(page.getByText('TAIL-MARKER', { exact: false })).toHaveCount(0);
});
