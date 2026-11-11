import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: 'tests',
  retries: 0,
  reporter: 'line',
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
});
