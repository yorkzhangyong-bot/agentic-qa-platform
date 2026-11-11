'use strict';
/*
 * locator-probe/playwright.cjs — records what each healed locator points to in the heal job's verification run, for
 * scripts/locator-check.sh. Loaded with NODE_OPTIONS=--require; it does nothing unless LOCATOR_PROBE_TARGETS (a JSON
 * list of locators, as Playwright's locator.toString() prints them) and LOCATOR_PROBE_OUT (a file) are set.
 *
 * It gives the test files a `test` from @playwright/test whose `page` fixture wraps Playwright's Locator actions and
 * assertions. The first time a test uses a locator that is a target, or ends with one (a locator chained on another),
 * it appends {target, locator, test, file, snapshot} to LOCATOR_PROBE_OUT, where snapshot is locator.ariaSnapshot():
 * the element's role and accessible name. It only reads the page. It leaves out the checks that don't wait, such as
 * isVisible(), so a test runs as before; an error is recorded instead of thrown.
 */
const fs = require('fs');
const Module = require('module');

const TIMEOUT = 5000;
// Locator methods that wait for their element anyway, and _expect, which every expect(locator) assertion calls.
const WAITING = ['click', 'dblclick', 'tap', 'hover', 'focus', 'blur', 'fill', 'clear', 'press', 'pressSequentially',
  'type', 'check', 'uncheck', 'setChecked', 'selectOption', 'selectText', 'setInputFiles', 'dragTo', 'dispatchEvent',
  'scrollIntoViewIfNeeded', 'screenshot', 'textContent', 'innerText', 'innerHTML', 'inputValue', 'getAttribute',
  'evaluate', 'waitFor', '_expect'];

function readTargets() {
  try {
    if (!process.env.LOCATOR_PROBE_TARGETS || !process.env.LOCATOR_PROBE_OUT)
      return [];
    const list = JSON.parse(fs.readFileSync(process.env.LOCATOR_PROBE_TARGETS, 'utf8'));
    return Array.isArray(list) ? list.filter(item => typeof item === 'string' && item) : [];
  } catch (error) {
    return [];
  }
}

const targets = readTargets();
if (targets.length)
  install(process.env.LOCATOR_PROBE_OUT);

function install(out) {
  const seen = new Set();
  const copies = new WeakMap();
  let current = { test: '', file: '' };
  let patched = false;

  async function probe(locator) {
    let description;
    try {
      description = String(locator);
    } catch (error) {
      return;
    }
    const target = targets.find(item => description === item || description.endsWith('.' + item));
    const key = `${current.file}\n${current.test}\n${description}`;
    if (!target || seen.has(key))
      return;
    seen.add(key);
    const record = { target, locator: description, test: current.test, file: current.file };
    try {
      record.snapshot = await locator.ariaSnapshot({ timeout: TIMEOUT });
    } catch (error) {
      record.error = String((error && error.message) || error).split('\n')[0];
    }
    try {
      fs.appendFileSync(out, JSON.stringify(record) + '\n');
    } catch (error) {
      // nowhere to record it: the check reports this locator as unknown
    }
  }

  function patch(page) {
    if (patched)
      return;
    patched = true;
    const proto = Object.getPrototypeOf(page.locator('html'));
    for (const name of WAITING) {
      const original = proto[name];
      if (typeof original !== 'function')
        continue;
      proto[name] = function(...args) {
        return probe(this).catch(() => {}).then(() => original.apply(this, args));
      };
    }
  }

  // @playwright/test exports its `test` function itself, with every export also a property of it (test.test === test,
  // test.expect, test.defineConfig, ...). The copy is then the extended test, which keeps its own describe, extend,
  // use and so on, plus the other exports. A module that exports a plain object gets a plain object.
  function withProbe(exported) {
    const base = exported && exported.test;
    if (!base || typeof base.extend !== 'function')
      return exported;
    if (copies.has(exported))
      return copies.get(exported);
    const test = base.extend({
      page: async ({ page }, use, testInfo) => {
        try {
          patch(page);
          current = { test: testInfo.titlePath.slice(1).join(' > '), file: testInfo.file };
        } catch (error) {
          // never stop a test
        }
        await use(page);
      },
    });
    const copy = exported === base ? test : {};
    for (const key of Object.keys(exported)) {
      if (!(key in copy))
        copy[key] = exported[key];
    }
    copy.test = test;
    if (exported.default === base)
      copy.default = test;
    if (exported.__esModule)
      Object.defineProperty(copy, '__esModule', { value: true });
    copies.set(exported, copy);
    copies.set(copy, copy);
    return copy;
  }

  const load = Module._load;
  Module._load = function(request) {
    const exported = load.apply(this, arguments);
    if (request !== '@playwright/test' && request !== 'playwright/test')
      return exported;
    try {
      return withProbe(exported);
    } catch (error) {
      return exported;
    }
  };
}
