import { expect, test as base, type APIRequestContext } from '@playwright/test';
import { randomUUID } from 'node:crypto';
import { startStubTarget, StubTarget } from './stub-target';

const API_URL = (process.env.KESTREL_API_URL ?? 'http://127.0.0.1:8000').replace(/\/$/, '');

export interface KestrelConfig {
  mode: string;
  defaults: { method: string; body_template: string; response_path: string };
  terms: { version: string; text: string };
  judge: { model: string; configured: boolean };
  attacker: { model: string; configured: boolean };
  adaptive: { max_turns: number; token_budget: number; time_limit_s: number };
  experience: { pattern_k: number; memory_cap: number; use_prior_experience_default: boolean };
}

export interface TurnDetail {
  position: number;
  attacker_message: string;
  reply_text: string | null;
  reply_truncated: boolean;
  judge_verdict: string | null;
  judge_reason: string | null;
  judge_progress: string | null;
}

export interface TargetDetail {
  id: number;
  name: string;
  url: string;
  method: string;
  permission_confirmed_at: string;
  terms_version: string;
  body_template: string;
  response_path: string;
  headers: Array<{ name: string; has_value: boolean; readable: boolean }>;
  canaries: string[];
}

export interface RunDetail {
  id: number;
  target_id: number;
  mode: string;
  prompt_id: string;
  prompt_title: string;
  family: string;
  owasp_category: string;
  status: string;
  prompt_text: string;
  reply_text: string | null;
  reply_truncated: boolean;
  verdict: string | null;
  hard_evidence: boolean;
  reason: string | null;
  judge_used: boolean;
  judge_model: string | null;
  attacker_source: string;
  failure_step: string | null;
  failure_message: string | null;
  started_at: string;
  finished_at: string | null;
  memory_written: boolean | null;
  use_prior_experience: boolean;
  // Adaptive runs (feature 003); null/empty for single-turn.
  attacker_model: string | null;
  turn_budget: number | null;
  turns_used: number | null;
  token_budget: number | null;
  tokens_used: number | null;
  time_limit_s: number | null;
  stopping_condition: string | null;
  succeeded_turn: number | null;
  turns: TurnDetail[];
}

export interface AttackPrompt {
  id: string;
  title: string;
  text: string;
  family: string;
  owasp_category: string;
  source: string;
}

export interface CreateTargetOptions {
  canaries?: string[];
  permission?: boolean;
  headers?: Array<{ name: string; value: string }>;
}

/** The label Streamlit renders for a run in "Open a run": started_at to the second, then the prompt title. */
export function runLabel(run: Pick<RunDetail, 'started_at' | 'prompt_title'>): string {
  return `${run.started_at.slice(0, 19).replace('T', ' ')} · ${run.prompt_title}`;
}

export function uniqueName(): string {
  return `QA 002 ${Date.now()}-${process.pid}-${randomUUID().slice(0, 8)}`;
}

/**
 * Thin client for Kestrel's API, used to seed a target and runs in the exact state a scenario needs and to read
 * the stored result back. Every target it creates is deleted again when the test ends.
 */
export class KestrelApi {
  private readonly created = new Set<number>();

  constructor(private readonly request: APIRequestContext) {}

  async config(): Promise<KestrelConfig> {
    const response = await this.request.get(`${API_URL}/api/config`);
    expect(response.ok(), `GET /api/config returned ${response.status()}`).toBe(true);
    return (await response.json()) as KestrelConfig;
  }

  /** Test the stub with a fresh form id, then save the target under the current terms version. */
  async createTarget(name: string, stub: StubTarget, options: CreateTargetOptions = {}): Promise<TargetDetail> {
    const config = await this.config();
    const formId = randomUUID();
    const settings = {
      url: stub.url,
      method: 'POST',
      headers: options.headers ?? [],
      body_template: '{"message": "{{prompt}}"}',
      response_path: '$.reply',
    };
    const tested = await this.request.post(`${API_URL}/api/connection-tests`, {
      data: { form_id: formId, target_id: null, settings },
    });
    expect(tested.status(), `connection test returned ${tested.status()}: ${await tested.text()}`).toBe(200);
    const outcome = (await tested.json()) as { ok: boolean; message?: string };
    expect(outcome.ok, `connection test failed: ${outcome.message ?? 'no message'}`).toBe(true);

    const response = await this.request.post(`${API_URL}/api/targets`, {
      data: {
        form_id: formId,
        name,
        settings,
        permission_confirmed: options.permission ?? true,
        terms_version: config.terms.version,
        canaries: options.canaries ?? [],
      },
    });
    expect(response.status(), `save target returned ${response.status()}: ${await response.text()}`).toBe(201);
    const target = (await response.json()) as TargetDetail;
    this.track(target.id);
    return target;
  }

  async createRun(
    targetId: number,
    options: { family: string; promptId?: string; mode?: 'single_turn' | 'adaptive'; usePriorExperience?: boolean },
  ): Promise<RunDetail> {
    const response = await this.request.post(`${API_URL}/api/runs`, {
      data: {
        target_id: targetId,
        family: options.family,
        prompt_id: options.promptId ?? null,
        mode: options.mode ?? 'single_turn',
        use_prior_experience: options.usePriorExperience ?? true,
      },
    });
    expect(response.status(), `POST /api/runs returned ${response.status()}: ${await response.text()}`).toBe(201);
    return (await response.json()) as RunDetail;
  }

  async getTarget(targetId: number): Promise<TargetDetail> {
    const response = await this.request.get(`${API_URL}/api/targets/${targetId}`);
    expect(response.ok(), `GET /api/targets/${targetId} returned ${response.status()}`).toBe(true);
    return (await response.json()) as TargetDetail;
  }

  async getTargetStatus(targetId: number): Promise<number> {
    const response = await this.request.get(`${API_URL}/api/targets/${targetId}`);
    return response.status();
  }

  async listRuns(targetId: number): Promise<RunDetail[]> {
    const response = await this.request.get(`${API_URL}/api/targets/${targetId}/runs`);
    expect(response.ok(), `GET /api/targets/${targetId}/runs returned ${response.status()}`).toBe(true);
    return (await response.json()) as RunDetail[];
  }

  async listRunStatus(targetId: number): Promise<number> {
    const response = await this.request.get(`${API_URL}/api/targets/${targetId}/runs`);
    return response.status();
  }

  async getRun(runId: number): Promise<RunDetail> {
    const response = await this.request.get(`${API_URL}/api/runs/${runId}`);
    expect(response.ok(), `GET /api/runs/${runId} returned ${response.status()}`).toBe(true);
    return (await response.json()) as RunDetail;
  }

  async getRunStatus(runId: number): Promise<number> {
    const response = await this.request.get(`${API_URL}/api/runs/${runId}`);
    return response.status();
  }

  async attackPrompts(family: string): Promise<AttackPrompt[]> {
    const response = await this.request.get(`${API_URL}/api/attack-prompts`, { params: { family } });
    expect(response.ok(), `GET /api/attack-prompts returned ${response.status()}`).toBe(true);
    return ((await response.json()) as { prompts: AttackPrompt[] }).prompts;
  }

  async findTargetByName(name: string): Promise<TargetDetail | undefined> {
    const response = await this.request.get(`${API_URL}/api/targets`);
    expect(response.ok(), `GET /api/targets returned ${response.status()}`).toBe(true);
    const targets = (await response.json()) as TargetDetail[];
    return targets.find((target) => target.name === name);
  }

  track(targetId: number): void {
    this.created.add(targetId);
  }

  async deleteTarget(targetId: number): Promise<void> {
    await this.request.delete(`${API_URL}/api/targets/${targetId}`);
    this.created.delete(targetId);
  }

  /** Best-effort teardown: a target already deleted by the test answers 404 and is simply forgotten. */
  async cleanup(): Promise<void> {
    for (const targetId of this.created) {
      await this.request.delete(`${API_URL}/api/targets/${targetId}`);
    }
    this.created.clear();
  }
}

export const test = base.extend<{ api: KestrelApi; stub: StubTarget }>({
  api: async ({ request }, use) => {
    const api = new KestrelApi(request);
    await use(api);
    await api.cleanup();
  },
  stub: async ({}, use) => {
    const stub = await startStubTarget();
    await use(stub);
    await stub.close();
  },
});

export { expect };
