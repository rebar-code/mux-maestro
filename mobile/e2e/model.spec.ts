import { expect, test, type Locator, type Page } from '@playwright/test';
import { drawer, fresh, threadPath } from './helpers';

const THREAD = 'localhost:7';

const sheet = (page: Page): Locator => page.locator('[data-model-sheet]');
const button = (page: Page): Locator => page.getByRole('button', { name: 'Model', exact: true });
const model = (page: Page, label: string): Locator =>
	sheet(page).locator(`[data-model="${label}"]`);
const effort = (page: Page, label: string): Locator =>
	sheet(page).locator(`[data-effort="${label}"]`);

/** Screenshots are taken only when SHOTS names a directory outside the repo. */
async function shot(page: Page, name: string): Promise<void> {
	const dir = process.env.SHOTS;
	if (dir) await page.screenshot({ path: `${dir}/${name}.png` });
}

/** The steps the phone sent to the pane's model menu, in order. */
async function steps(page: Page): Promise<Record<string, unknown>[]> {
	const sent = await (await page.request.post('/__fixture/replies')).json();
	return sent.model as Record<string, unknown>[];
}

/** What the session runs, and whether the agent's menu is open in the pane. */
async function pane(page: Page): Promise<{ now: unknown; open: boolean }> {
	return (await page.request.post(`/__fixture/model-now?id=${THREAD}`)).json();
}

async function open(page: Page, agent: 'claude' | 'codex' = 'claude'): Promise<void> {
	await fresh(page);
	await page.request.post('/__fixture/capability?name=replies&on=1');
	await page.request.post(`/__fixture/status?id=${THREAD}&value=idle`);
	await page.request.post(`/__fixture/model-agent?id=${THREAD}&agent=${agent}`);
	await page.goto(threadPath(THREAD));
	await expect(button(page)).toBeEnabled();
}

test('a Claude session: pick a model and an effort level', async ({ page }) => {
	await open(page);
	await shot(page, 'model-1-header');
	await button(page).click();
	await expect(sheet(page)).toHaveAttribute('data-model-sheet', 'models');
	await expect(sheet(page).locator('.title')).toHaveText('Model');
	await expect(sheet(page).locator('[data-model]')).toHaveText([
		'Default (recommended)',
		'Opus 5.5',
		'Fable 5.1',
		'Sonnet 5.5',
		'Haiku 5.5',
		'Haiku 4.5'
	]);
	await expect(sheet(page).locator('[aria-current="true"]')).toHaveText('Opus 5.5');
	await shot(page, 'model-2-claude-models');

	await model(page, 'Haiku 5.5').click();
	await expect(sheet(page)).toHaveAttribute('data-model-sheet', 'efforts');
	await expect(sheet(page).locator('.title')).toHaveText('Haiku 5.5 effort');
	await expect(sheet(page).locator('[data-effort]')).toHaveText([
		'Low',
		'Medium',
		'High',
		'xHigh',
		'Max'
	]);
	await shot(page, 'model-3-claude-efforts');

	await effort(page, 'Low').click();
	await expect(sheet(page)).toBeHidden();
	expect(await pane(page)).toEqual({ now: { model: 'Haiku 5.5', effort: 'Low' }, open: false });
	// The pick closed the agent's menu: no cancel follows it.
	expect((await steps(page)).map((step) => step.step)).toEqual(['open', 'model', 'apply']);

	// The next visit reads the menu again: the pick is the current model.
	await button(page).click();
	await expect(sheet(page).locator('[aria-current="true"]')).toHaveText('Haiku 5.5');
	await model(page, 'Haiku 5.5').click();
	await expect(sheet(page).locator('[aria-current="true"]')).toHaveText('Low');
});

test('a model without effort levels is taken at the first tap', async ({ page }) => {
	await open(page);
	await button(page).click();
	await model(page, 'Haiku 4.5').click();
	await expect(sheet(page)).toBeHidden();
	expect(await pane(page)).toEqual({ now: { model: 'Haiku 4.5', effort: null }, open: false });
});

test('a Codex session gets its own models and levels', async ({ page }) => {
	await open(page, 'codex');
	await button(page).click();
	await expect(sheet(page).locator('[data-model]')).toHaveText([
		'GPT-6.1-Sol',
		'GPT-6-Astra',
		'GPT-6-Sol',
		'GPT-6-Luna'
	]);
	await expect(sheet(page).locator('[aria-current="true"]')).toHaveText('GPT-6-Luna');
	await shot(page, 'model-4-codex-models');
	await model(page, 'GPT-6-Astra').click();
	await expect(sheet(page).locator('[data-effort]')).toHaveText([
		'Low',
		'Medium',
		'High',
		'Extra high'
	]);
	await shot(page, 'model-5-codex-efforts');
	await effort(page, 'High').click();
	await expect(sheet(page)).toBeHidden();
	expect(await pane(page)).toEqual({ now: { model: 'GPT-6-Astra', effort: 'High' }, open: false });
});

test('Back returns to the models; Cancel closes the menu in the pane', async ({ page }) => {
	await open(page);
	await button(page).click();
	await model(page, 'Fable 5.1').click();
	await sheet(page).getByRole('button', { name: 'Back' }).click();
	await expect(sheet(page)).toHaveAttribute('data-model-sheet', 'models');
	expect((await pane(page)).open).toBe(true);

	await sheet(page).getByRole('button', { name: 'Cancel' }).click();
	await expect(sheet(page)).toBeHidden();
	await expect.poll(async () => (await pane(page)).open).toBe(false);
	expect((await pane(page)).now).toEqual({ model: 'Opus 5.5', effort: 'High' });
	expect((await steps(page)).at(-1)?.step).toBe('cancel');
});

test('leaving the thread closes the menu in the pane', async ({ page }) => {
	await open(page);
	// Into the thread by the drawer, so Back stays inside the app.
	await page.goto('/');
	await page.getByRole('button', { name: 'Menu' }).click();
	await drawer(page).locator(`[data-thread="${THREAD}"]`).click();
	await button(page).click();
	await expect(sheet(page).locator('[data-model]').first()).toBeVisible();
	await page.goBack();
	await expect(sheet(page)).toBeHidden();
	await expect.poll(async () => (await pane(page)).open).toBe(false);
});

test('a refusal is shown, and the lists go', async ({ page }) => {
	await open(page);
	await button(page).click();
	await page.request.post(
		'/__fixture/model-fail?error=changed&message=The%20model%20menu%20changed'
	);
	await model(page, 'Sonnet 5.5').click();
	await expect(sheet(page).getByRole('alert')).toHaveText('The model menu changed');
	await expect(sheet(page).locator('[data-model]')).toHaveCount(0);
	await shot(page, 'model-6-refused');
	await sheet(page).getByRole('button', { name: 'Cancel' }).click();
	await expect(sheet(page)).toBeHidden();
});

test('a busy agent is not asked', async ({ page }) => {
	await open(page);
	await page.request.post(`/__fixture/status?id=${THREAD}&value=busy`);
	await expect(button(page)).toBeDisabled();
	expect(await steps(page)).toEqual([]);
});

test('no button with replies off, or on a pane without an agent', async ({ page }) => {
	await fresh(page, threadPath(THREAD));
	await expect(page.getByRole('button', { name: 'Find' })).toBeVisible();
	await expect(button(page)).toHaveCount(0);

	await page.request.post('/__fixture/capability?name=replies&on=1');
	await page.goto(threadPath('buildbox:8'));
	await expect(page.getByRole('button', { name: 'Find' })).toBeVisible();
	await expect(button(page)).toHaveCount(0);
});
