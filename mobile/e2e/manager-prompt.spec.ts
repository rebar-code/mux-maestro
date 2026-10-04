import { mkdirSync } from 'node:fs';
import { expect, test, type Locator, type Page } from '@playwright/test';
import { forget, pairingLink, reset, threadPath } from './helpers';

/** A listed thread that waits on a permission prompt. */
const PERMISSION = 'localhost:1';

interface Key {
	key: string;
	prompt?: string;
	terminal?: boolean;
}

interface Received {
	keys: (Key & { thread: string })[];
	answers: { thread: string; prompt: string; option: number }[];
	cancels: { thread: string; prompt: string }[];
	manager: {
		keys: Key[];
		answers: { prompt: string; option: number }[];
		cancels: { prompt: string }[];
		promptFetches: number;
	};
}

const QUESTION = 'Which rule should a plan downgrade use?';

const card = (page: Page): Locator => page.locator('[data-prompt]');
const options = (page: Page): Locator => card(page).locator('[data-option]');
const cancel = (page: Page): Locator => card(page).getByRole('button', { name: 'Cancel' });
const keybar = (page: Page): Locator => page.locator('[data-keybar]');
const key = (page: Page, name: string): Locator =>
	keybar(page).getByRole('button', { name, exact: true });
const note = (page: Page): Locator => page.locator('[data-note]');
const ask = (page: Page): Locator => page.getByRole('textbox', { name: 'Ask the Maestro' });
const tab = (page: Page): Locator => page.locator('[data-tab="main"]');

async function received(page: Page): Promise<Received> {
	return (await (await page.request.post('/__fixture/replies')).json()) as Received;
}

/** Open the manager home, or a thread, with these features on and these hooks run first. */
async function open(page: Page, on: string[], hooks: string[] = [], path = '/'): Promise<void> {
	await reset(page);
	for (const name of on) await page.request.post(`/__fixture/capability?name=${name}&on=1`);
	for (const hook of hooks) await page.request.post(hook);
	await forget(page);
	await page.goto(pairingLink(path));
}

/** Screenshots are taken only when SHOTS names a directory outside the repo. */
async function shot(page: Page, name: string): Promise<void> {
	const dir = process.env.SHOTS;
	if (!dir) return;
	mkdirSync(dir, { recursive: true });
	await page.waitForTimeout(250);
	await page.screenshot({ path: `${dir}/${name}.png` });
}

/** Every request the page makes to a thread route with the manager as its id: none is right. */
function threadRoutes(page: Page): string[] {
	const seen: string[] = [];
	page.on('request', (request) => {
		const path = new URL(request.url()).pathname;
		if (path.startsWith('/api/threads/manager')) seen.push(path);
	});
	return seen;
}

test('the manager waits on a question: the home shows the card, and an option answers it', async ({
	page
}) => {
	const wrong = threadRoutes(page);
	await open(page, ['replies', 'keyBar'], ['/__fixture/manager-prompt?pid=mq-1']);
	await expect(ask(page)).toBeVisible();
	await expect(card(page)).toHaveAttribute('data-prompt', 'mq-1');
	await expect(card(page)).toHaveAttribute('data-kind', 'question');
	// The question is the thing to read.
	await expect(card(page).locator('.q')).toHaveText(QUESTION);
	await expect(card(page).locator('.q')).toHaveCSS('font-weight', '600');
	await expect(options(page)).toHaveText([
		/Credit the unused days\s*1$/,
		/No credit until renewal\s*2$/,
		/Type something else\s*3$/
	]);
	await expect(card(page).locator('[aria-current="true"]')).toHaveAttribute('data-option', '1');
	for (const option of await options(page).all())
		expect((await option.boundingBox())?.height).toBeGreaterThanOrEqual(44);
	// On screen without scrolling, above the footer; the board is below the footer.
	await expect(card(page)).toBeInViewport({ ratio: 1 });
	const at = await card(page).boundingBox();
	const foot = await page.locator('[data-foot]').boundingBox();
	expect((at?.y ?? 0) + (at?.height ?? 0)).toBeLessThanOrEqual(foot?.y ?? 0);
	// The keys are in the footer, under its grabber and above the text box.
	const keys = await keybar(page).boundingBox();
	const grab = await page.locator('[data-grab]').boundingBox();
	const form = await page.locator('form.compose').boundingBox();
	expect(keys?.y).toBeGreaterThanOrEqual((grab?.y ?? 0) + (grab?.height ?? 0));
	expect((keys?.y ?? 0) + (keys?.height ?? 0)).toBeLessThanOrEqual(form?.y ?? 0);

	// With the board raised the footer rises with it: the keys and the card stay clear.
	await page.locator('[data-grab]').click();
	await expect(page.locator('[data-board]')).toHaveAttribute('data-stop', '1');
	await page.waitForTimeout(400);
	const raised = await keybar(page).boundingBox();
	const board = await page.locator('[data-board]').boundingBox();
	expect((raised?.y ?? 0) + (raised?.height ?? 0)).toBeLessThanOrEqual(board?.y ?? 0);
	await expect(card(page)).toBeInViewport({ ratio: 1 });
	const lifted = await card(page).boundingBox();
	const footUp = await page.locator('[data-foot]').boundingBox();
	expect((lifted?.y ?? 0) + (lifted?.height ?? 0)).toBeLessThanOrEqual(footUp?.y ?? 0);
	// Back down for the rest.
	await page.locator('[data-grab]').click();
	await page.locator('[data-grab]').click();
	await expect(page.locator('[data-board]')).toHaveAttribute('data-stop', '0');
	await page.waitForTimeout(400);
	// The line the home had before is still there.
	await expect(page.locator('[data-status="waiting"]')).toHaveText(
		'Manager is waiting on a prompt'
	);
	await shot(page, 'manager-card');

	const sent = page.waitForRequest((request) => request.url().endsWith('/api/manager/answer'));
	await options(page).nth(1).tap();
	const request = await sent;
	expect(request.method()).toBe('POST');
	expect(request.headers()['x-muxmaestro']).toBe('1');
	expect(request.headers()['x-muxmaestro-token']).toBe('demo-token');
	expect(request.postDataJSON()).toEqual({ prompt: 'mq-1', option: 2 });

	await expect(card(page)).toHaveCount(0);
	// The wait is over, and the home says so without a ten-second lag.
	await expect(page.locator('[data-status="waiting"]')).toHaveCount(0);
	const got = await received(page);
	expect(got.manager.answers).toEqual([{ prompt: 'mq-1', option: 2 }]);
	expect(got.answers).toEqual([]);
	// The manager is not a listed thread: nothing went to a thread route.
	expect(wrong).toEqual([]);
});

test('Cancel on the manager card dismisses the prompt', async ({ page }) => {
	await open(page, ['replies'], ['/__fixture/manager-prompt?pid=mq-1']);
	await expect(card(page)).toHaveAttribute('data-prompt', 'mq-1');
	// After the options, and as large as a finger.
	await expect(card(page).getByRole('button')).toHaveText([/1$/, /2$/, /3$/, 'Cancel']);
	expect((await cancel(page).boundingBox())?.height).toBeGreaterThanOrEqual(44);
	await expect(cancel(page)).not.toHaveCSS('background-color', 'rgb(50, 145, 255)');

	let release: () => void = () => {};
	const held = new Promise<void>((done) => (release = done));
	await page.route('**/api/manager/answer', async (route) => {
		await held;
		await route.continue();
	});
	const sent = page.waitForRequest((request) => request.url().endsWith('/api/manager/answer'));
	await cancel(page).tap();
	expect((await sent).postDataJSON()).toEqual({ prompt: 'mq-1', cancel: true });
	// One request at a time: every control of the card waits.
	for (const button of await card(page).getByRole('button').all())
		await expect(button).toBeDisabled();
	await expect(cancel(page)).toHaveAttribute('aria-busy', 'true');
	release();
	await expect(card(page)).toHaveCount(0);
	const got = await received(page);
	expect(got.manager.cancels).toEqual([{ prompt: 'mq-1' }]);
	expect(got.manager.answers).toEqual([]);
});

test('a stale manager card is replaced, and nothing is sent again', async ({ page }) => {
	await open(page, ['replies'], ['/__fixture/manager-prompt?pid=mq-1']);
	await expect(card(page)).toHaveAttribute('data-prompt', 'mq-1');
	// The pane moved on, and the phone has not been told.
	await page.request.post('/__fixture/manager-prompt?pid=mq-2&kind=permission');
	let posts = 0;
	page.on('request', (request) => {
		if (request.url().endsWith('/api/manager/answer')) posts += 1;
	});
	const refused = page.waitForResponse((response) =>
		response.url().endsWith('/api/manager/answer')
	);
	await options(page).nth(0).tap();
	expect((await refused).status()).toBe(409);
	await expect(card(page)).toHaveAttribute('data-prompt', 'mq-2');
	await expect(card(page)).toHaveAttribute('data-kind', 'permission');
	await page.waitForTimeout(400);
	expect(posts).toBe(1);
	expect((await received(page)).manager.answers).toEqual([]);

	// A stale Cancel is not sent again either.
	await page.request.post('/__fixture/manager-prompt?pid=mq-3');
	await cancel(page).tap();
	await expect(card(page)).toHaveAttribute('data-prompt', 'mq-3');
	await page.waitForTimeout(300);
	expect(posts).toBe(2);
	expect((await received(page)).manager.cancels).toEqual([]);
});

test('with the key bar alone the manager card is read-only, and Escape goes to the manager', async ({
	page
}) => {
	const wrong = threadRoutes(page);
	await open(page, ['keyBar'], ['/__fixture/manager-prompt?pid=mq-1']);
	await expect(card(page)).toHaveAttribute('data-readonly', '');
	await expect(card(page).locator('.q')).toHaveText(QUESTION);
	await expect(options(page)).toHaveCount(3);
	await expect(card(page).locator('[aria-current="true"]')).toHaveText(/^❯/);
	// Nothing on it can be pressed: no options, no Cancel.
	await expect(card(page).getByRole('button')).toHaveCount(0);

	// The pane's keys, above the voice bar and the manager's own text box.
	await expect(keybar(page)).toBeVisible();
	await expect(keybar(page).locator('.keys button')).toHaveText([
		'Esc',
		'Tab',
		'Sh+Tab',
		'Ctrl+C',
		'←',
		'↓',
		'↑',
		'→',
		'⏎'
	]);
	const bar = await keybar(page).boundingBox();
	const form = await page.locator('form.compose').boundingBox();
	expect((bar?.y ?? 0) + (bar?.height ?? 0)).toBeLessThanOrEqual(form?.y ?? 0);
	// Under the stage, so the board sheet never covers it.
	const stage = await page.locator('.stage').boundingBox();
	expect((stage?.y ?? 0) + (stage?.height ?? 0)).toBeLessThanOrEqual((bar?.y ?? 0) + 1);

	const sent = page.waitForRequest((request) => request.url().endsWith('/api/manager/key'));
	await key(page, 'Escape').tap();
	const request = await sent;
	expect(request.headers()['x-muxmaestro']).toBe('1');
	// The chat is on screen, not the terminal.
	expect(request.postDataJSON()).toEqual({ key: 'Escape', prompt: 'mq-1' });
	await expect
		.poll(async () => (await received(page)).manager.keys)
		.toEqual([{ key: 'Escape', prompt: 'mq-1' }]);

	// An arrow moves the mark, as on a thread.
	await key(page, 'Down').tap();
	await expect(card(page).locator('[aria-current="true"]')).toHaveAttribute('data-option', '2');
	expect((await received(page)).keys).toEqual([]);
	expect(wrong).toEqual([]);
});

test('a manager prompt with no readable choices: the terminal, and Enter from there', async ({
	page
}) => {
	await open(page, ['replies', 'keyBar'], ['/__fixture/manager-prompt?pid=mb-1&bare=1']);
	await expect(card(page)).toHaveAttribute('data-kind', 'bare');
	await expect(card(page).locator('h3')).toHaveText('Waiting on a prompt');
	await expect(card(page).getByRole('button')).toHaveText(['Show terminal', 'Cancel']);

	// From the chat nobody can read what Enter would pick.
	const refused = page.waitForResponse((response) => response.url().endsWith('/api/manager/key'));
	await key(page, 'Enter').tap();
	const answer = await refused;
	expect(answer.status()).toBe(409);
	expect(answer.request().postDataJSON()).toEqual({ key: 'Enter', prompt: 'mb-1' });
	await expect(note(page)).toHaveText('Open the terminal to answer');
	expect((await received(page)).manager.keys).toEqual([]);

	// The terminal has the pane's own text.
	await card(page).getByRole('button', { name: 'Show terminal' }).tap();
	await expect(tab(page)).toHaveText(/Terminal\s*⇄/);
	await expect(page.locator('.screen')).toBeVisible();
	await expect(keybar(page)).toBeVisible();
	await shot(page, 'manager-terminal-keys');

	// With it on screen, Enter says so and is taken.
	const sent = page.waitForRequest((request) => request.url().endsWith('/api/manager/key'));
	await key(page, 'Enter').tap();
	expect((await sent).postDataJSON()).toEqual({ key: 'Enter', prompt: 'mb-1', terminal: true });
	await expect
		.poll(async () => (await received(page)).manager.keys)
		.toEqual([{ key: 'Enter', prompt: 'mb-1', terminal: true }]);
	await expect(note(page)).toHaveCount(0);

	// Back on the chat the flag is gone again.
	await tab(page).tap();
	await expect(tab(page)).toHaveText(/Chat\s*⇄/);
	const again = page.waitForRequest((request) => request.url().endsWith('/api/manager/key'));
	await key(page, 'Escape').tap();
	expect((await again).postDataJSON()).toEqual({ key: 'Escape', prompt: 'mb-1' });
});

test('a manager that does not wait shows no card, and is asked once', async ({ page }) => {
	await open(page, ['replies', 'keyBar']);
	await expect(ask(page)).toBeVisible();
	await expect(page.locator('.a').first()).toBeVisible();
	// Longer than two prompt polls of a waiting pane.
	await page.waitForTimeout(7000);
	await expect(card(page)).toHaveCount(0);
	expect((await received(page)).manager.promptFetches).toBeLessThanOrEqual(1);
});

test('with both switches off the manager prompt is never asked for', async ({ page }) => {
	const asked: string[] = [];
	page.on('request', (request) => {
		if (request.url().endsWith('/api/manager/prompt')) asked.push(request.url());
	});
	await open(page, [], ['/__fixture/manager-prompt?pid=mq-1']);
	await expect(ask(page)).toBeVisible();
	await expect(page.locator('[data-status="waiting"]')).toBeVisible();
	await page.waitForTimeout(4000);
	await expect(card(page)).toHaveCount(0);
	await expect(keybar(page)).toHaveCount(0);
	expect(asked).toEqual([]);
	expect((await received(page)).manager.promptFetches).toBe(0);

	// The Mac switches replies on: the card comes, with no reload.
	await page.request.post('/__fixture/capability?name=replies&on=1');
	await expect(card(page)).toHaveAttribute('data-prompt', 'mq-1');
});

test('Cancel on a thread card dismisses the prompt', async ({ page }) => {
	await open(page, ['replies', 'keyBar'], [], threadPath(PERMISSION));
	await expect(card(page)).toHaveAttribute('data-kind', 'permission');
	const shown = await card(page).getAttribute('data-prompt');
	expect((await cancel(page).boundingBox())?.height).toBeGreaterThanOrEqual(44);
	const sent = page.waitForRequest((request) => request.url().endsWith('/answer'));
	await cancel(page).tap();
	const request = await sent;
	expect(new URL(request.url()).pathname).toBe('/api/threads/localhost%3A1/answer');
	expect(request.postDataJSON()).toEqual({ prompt: shown, cancel: true });
	await expect(card(page)).toHaveCount(0);
	const got = await received(page);
	expect(got.cancels).toEqual([{ thread: PERMISSION, prompt: shown }]);
	expect(got.answers).toEqual([]);
	expect(got.manager.cancels).toEqual([]);
});

test('on a thread, a key says when the terminal was on screen', async ({ page }) => {
	await open(page, ['replies', 'keyBar'], [], threadPath(PERMISSION));
	await expect(card(page)).toBeVisible();
	await page.request.post(`/__fixture/prompt?id=${PERMISSION}&pid=bare-9&bare=1`);
	await expect(card(page)).toHaveAttribute('data-kind', 'bare');
	// A prompt nobody can read has a way out too.
	await expect(cancel(page)).toBeVisible();

	// From the chat, Enter is refused.
	const refused = page.waitForResponse((response) => response.url().endsWith('/key'));
	await key(page, 'Enter').tap();
	const answer = await refused;
	expect(answer.status()).toBe(409);
	expect(answer.request().postDataJSON()).toEqual({ key: 'Enter', prompt: 'bare-9' });

	// From the terminal it is taken: the human could read the pane.
	await card(page).getByRole('button', { name: 'Show terminal' }).tap();
	await expect(tab(page)).toHaveText(/Terminal\s*⇄/);
	const sent = page.waitForRequest((request) => request.url().endsWith('/key'));
	await key(page, 'Enter').tap();
	expect((await sent).postDataJSON()).toEqual({ key: 'Enter', prompt: 'bare-9', terminal: true });
	await expect
		.poll(async () => (await received(page)).keys)
		.toEqual([{ thread: PERMISSION, key: 'Enter', prompt: 'bare-9', terminal: true }]);
});

test('the read-only thread card has no Cancel', async ({ page }) => {
	await open(page, ['keyBar'], [], threadPath(PERMISSION));
	await expect(card(page)).toHaveAttribute('data-readonly', '');
	await expect(cancel(page)).toHaveCount(0);
});
