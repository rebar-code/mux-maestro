import { mkdirSync } from 'node:fs';
import { expect, test, type APIResponse, type Locator, type Page } from '@playwright/test';
import {
	fakeMic,
	forget,
	pairingLink,
	reset,
	threadPath,
	TOKEN_HEADER,
	touchDrag,
	twoFingers
} from './helpers';

/** Idle, local, with a chat. */
const IDLE = 'localhost:7';
const BUSY = 'localhost:3';
/** Waits on a permission prompt; has a chat. */
const PERMISSION = 'localhost:1';
/** Waits on a question; remote, so it shows the terminal. */
const QUESTION = 'devbox:2';

type Capability = 'replies' | 'keyBar' | 'upload' | 'voice';

interface Replies {
	texts: { thread: string; text: string; spoken?: boolean }[];
	keys: { thread: string; key: string; prompt?: string }[];
	/** Texts the pane was left holding, unsent. */
	left: { thread: string; text: string }[];
	answers: { thread: string; prompt: string; option: number }[];
	commandFetches: number;
}

const WRITE = { ...TOKEN_HEADER, 'X-MuxMaestro': '1' };

const box = (page: Page): Locator => page.getByRole('textbox', { name: 'Reply' });
const sendButton = (page: Page): Locator => page.getByRole('button', { name: /^Send(ing)?$/ });
/** Submit the composer's form, as Enter on real keys does. On a phone, Return is a new line. */
const submit = (page: Page): Promise<void> =>
	page.locator('form.compose').evaluate((form: HTMLFormElement) => form.requestSubmit());
const note = (page: Page): Locator => page.locator('[data-note]');
const keybar = (page: Page): Locator => page.locator('[data-keybar]');
const key = (page: Page, name: string): Locator =>
	keybar(page).getByRole('button', { name, exact: true });
const slash = (page: Page): Locator => page.locator('[data-slash]');
const card = (page: Page): Locator => page.locator('[data-prompt]');
const nextBar = (page: Page): Locator => page.locator('[data-next]');
/** The pill beside an empty box: the voice button, switched off while Voice is off on the Mac. */
const idlePill = (page: Page): Locator => page.locator('[data-compose] [data-primary="talk"]');
/** The voice bar with its controls. Switched off, the bar is one line with none. */
const voiceControls = (page: Page): Locator =>
	page.locator('[data-voicebar]:not([data-voice="off"])');
/** The reply box while replies are switched off on the Mac. */
const offBox = (page: Page): Locator =>
	page.getByRole('textbox', { name: 'Off in MuxMaestro Settings' });

async function received(page: Page): Promise<Replies> {
	return (await (await page.request.post('/__fixture/replies')).json()) as Replies;
}

/** Open a thread with these features switched on at the Mac. */
async function open(page: Page, id: string, on: Capability[], hooks: string[] = []): Promise<void> {
	await reset(page);
	for (const name of on) await page.request.post(`/__fixture/capability?name=${name}&on=1`);
	for (const hook of hooks) await page.request.post(hook);
	await forget(page);
	await page.goto(pairingLink(threadPath(id)));
	await expect(page.locator('.tbar .title b')).toBeVisible();
}

/** Screenshots are taken only when SHOTS names a directory outside the repo. */
async function shot(page: Page, name: string): Promise<void> {
	const dir = process.env.SHOTS;
	if (!dir) return;
	mkdirSync(dir, { recursive: true });
	// Let the last transition and the fonts settle.
	await page.waitForTimeout(250);
	await page.screenshot({ path: `${dir}/${name}.png` });
}

test('a reply is sent, shows in the chat, and the box clears', async ({ page }) => {
	await open(page, IDLE, ['replies', 'keyBar']);
	// Return is a new line on a phone: the button sends.
	await expect(box(page)).toHaveAttribute('enterkeyhint', 'enter');
	await expect(box(page)).toHaveAttribute('placeholder', 'Reply');
	await expect(idlePill(page)).toBeDisabled();
	await shot(page, 'composer');

	await box(page).fill('ship it');
	const sent = page.waitForRequest((request) => request.url().endsWith('/text'));
	await sendButton(page).click();
	const request = await sent;
	expect(request.method()).toBe('POST');
	expect(new URL(request.url()).pathname).toBe('/api/threads/localhost%3A7/text');
	expect(request.headers()['x-muxmaestro']).toBe('1');
	expect(request.headers()['x-muxmaestro-token']).toBe('demo-token');
	expect(request.postDataJSON()).toEqual({ text: 'ship it' });

	await expect(box(page)).toHaveValue('');
	await expect(page.locator('.u').last()).toHaveText('ship it');
	await expect(page.locator('.a').last()).toHaveText('Done: ship it. 2 files changed, tests pass.');
	expect((await received(page)).texts).toEqual([{ thread: IDLE, text: 'ship it' }]);

	// The form sends too, as Enter on real keys does.
	await expect(page.locator('.tbar .title span')).toContainText('idle');
	await box(page).fill('and open a PR');
	await submit(page);
	await expect(page.locator('.u').last()).toHaveText('and open a PR');
	await expect(box(page)).toHaveValue('');
});

test('a busy thread takes typing but not Send', async ({ page }) => {
	await open(page, BUSY, ['replies']);
	await box(page).fill('one more thing');
	await expect(box(page)).toHaveValue('one more thing');
	await expect(sendButton(page)).toBeDisabled();
	await submit(page);
	await page.waitForTimeout(300);
	expect((await received(page)).texts).toEqual([]);
	await expect(box(page)).toHaveValue('one more thing');

	// It goes idle: Send works, with the text still there.
	await page.request.post(`/__fixture/status?id=${BUSY}&value=idle`);
	await expect(sendButton(page)).toBeEnabled();
});

test('a refused reply keeps its text and says why', async ({ page }) => {
	await open(page, IDLE, ['replies']);
	// The pane started a turn the phone has not heard of yet.
	await page.route('**/api/threads/*/text', (route) =>
		route.fulfill({ status: 409, json: { error: 'busy', message: 'dark-mode is running a turn' } })
	);
	await box(page).fill('ship it');
	await sendButton(page).click();
	await expect(note(page)).toHaveText('dark-mode is running a turn');
	await expect(box(page)).toHaveValue('ship it');

	await page.unroute('**/api/threads/*/text');
	await page.route('**/api/threads/*/text', (route) =>
		route.fulfill({ status: 413, json: { error: 'too_large' } })
	);
	await sendButton(page).click();
	await expect(note(page)).toHaveText('Too long');
	await expect(box(page)).toHaveValue('ship it');
	// Typing clears the line.
	await box(page).pressSequentially('!');
	await expect(note(page)).toHaveCount(0);
});

test('the fixture refuses what the Mac refuses', async ({ page }) => {
	await reset(page);
	const origin = new URL(test.info().project.use.baseURL ?? '').origin;
	const post = (
		path: string,
		data: unknown,
		headers: Record<string, string> = WRITE,
		id = IDLE
	): Promise<APIResponse> =>
		page.request.post(`/api/threads/${encodeURIComponent(id)}/${path}`, {
			data,
			headers: { ...headers, origin }
		});
	const error = async (response: APIResponse): Promise<unknown> => [
		response.status(),
		((await response.json()) as { error: string }).error
	];

	// Off until the Mac switches them on.
	expect(await error(await post('text', { text: 'hi' }))).toEqual([403, 'disabled']);
	expect(await error(await post('key', { key: 'Enter' }))).toEqual([403, 'disabled']);
	expect(await error(await post('upload?name=a.txt', 'x'))).toEqual([403, 'disabled']);
	for (const name of ['replies', 'keyBar', 'upload'])
		await page.request.post(`/__fixture/capability?name=${name}&on=1`);

	expect(await error(await post('text', { text: 'hi' }, {}))).toEqual([401, 'unpaired']);
	expect(await error(await post('text', { text: 'hi' }, TOKEN_HEADER))).toEqual([403, 'forbidden']);
	expect(await error(await post('text', { text: '  ' }))).toEqual([400, 'bad_request']);
	expect(await error(await post('text', { text: 'a\u001bb' }))).toEqual([400, 'bad_request']);
	expect(await error(await post('text', { text: 'x'.repeat(8193) }))).toEqual([413, 'too_large']);
	expect((await post('text', { text: 'x'.repeat(8192) })).status()).toBe(200);
	// The turn that just started makes the pane busy.
	expect(await error(await post('text', { text: 'again' }))).toEqual([409, 'busy']);
	expect(await error(await post('upload?name=a.txt', 'x'))).toEqual([409, 'busy']);

	for (const bad of ['F1', 'enter', 'C-A', '0', 'a', ''])
		expect(await error(await post('key', { key: bad }))).toEqual([400, 'bad_key']);
	for (const good of ['Enter', 'BTab', 'C-z', '9'])
		expect((await post('key', { key: good })).status()).toBe(200);

	const other = (path: string, data: unknown): Promise<APIResponse> =>
		post(path, data, WRITE, PERMISSION);
	expect(await error(await other('text', { text: 'hi' }))).toEqual([409, 'waiting']);
	expect(await error(await other('answer', { prompt: 'nope', option: 1 }))).toEqual([409, 'stale']);
	expect(await error(await other('answer', { prompt: 'nope' }))).toEqual([400, 'bad_request']);
	expect(await error(await post('text', { text: 'hi' }, WRITE, 'none:1'))).toEqual([
		404,
		'not_found'
	]);

	await page.request.post('/__fixture/upload-max?value=4');
	await page.request.post(`/__fixture/status?id=${IDLE}&value=idle`);
	expect(await error(await post('upload?name=a.txt', 'too many bytes'))).toEqual([
		413,
		'too_large'
	]);
});

test('key bar: keys go to the pane, text keys go to the box', async ({ page }) => {
	await open(page, IDLE, ['replies', 'keyBar']);
	await expect(keybar(page).locator('.keys button')).toHaveText([
		'Esc',
		'Tab',
		'Sh+Tab',
		'Ctrl',
		'Ctrl+C',
		'←',
		'↓',
		'↑',
		'→',
		'⏎',
		'/',
		'~',
		'|',
		'-'
	]);

	// Every key has a name. The strip is slim by design: about 60% of a full
	// touch row, with the keys still clear of each other.
	const sizes = await keybar(page)
		.locator('.keys')
		.evaluate((keys) => {
			const buttons = [...keys.querySelectorAll('button')];
			return buttons.map((button, index) => {
				keys.scrollLeft = Math.max(0, button.offsetLeft - 20);
				const rect = button.getBoundingClientRect();
				const x = rect.left + rect.width / 2;
				const y = rect.top + rect.height / 2;
				const next = buttons[index + 1]?.getBoundingClientRect();
				return {
					label: button.getAttribute('aria-label'),
					width: rect.width,
					top: document.elementFromPoint(x, y - 11) === button,
					bottom: document.elementFromPoint(x, y + 11) === button,
					gap: next ? next.left - rect.right : 5
				};
			});
		});
	for (const size of sizes) {
		expect(size.label, JSON.stringify(size)).toBeTruthy();
		expect(size.width, JSON.stringify(size)).toBeGreaterThanOrEqual(28);
		expect(size.top && size.bottom, JSON.stringify(size)).toBe(true);
		expect(size.gap, JSON.stringify(size)).toBeGreaterThanOrEqual(5);
	}
	const strip = await keybar(page).boundingBox();
	expect(strip?.height).toBeLessThanOrEqual(32);
	await keybar(page)
		.locator('.keys')
		.evaluate((keys) => (keys.scrollLeft = 0));
	// One key at the strip's end puts the keyboard away; it is not one of the scrolling keys.
	await expect(keybar(page).getByRole('button', { name: 'Hide keyboard' })).toHaveCount(1);
	await expect(
		keybar(page).locator('.keys').getByRole('button', { name: 'Hide keyboard' })
	).toHaveCount(0);

	// A tap on a key leaves the focus in the box, so the keyboard stays up.
	await box(page).tap();
	await expect(box(page)).toBeFocused();
	await key(page, 'Escape').tap();
	await key(page, 'Tab').tap();
	await key(page, 'Shift Tab').tap();
	await key(page, 'Control C').tap();
	await expect(box(page)).toBeFocused();
	await expect.poll(async () => (await received(page)).keys.length).toBe(4);

	const moveTo = (name: string): Promise<void> =>
		keybar(page)
			.locator('.keys')
			.evaluate((keys, label) => {
				const button = keys.querySelector<HTMLElement>(`[aria-label="${label}"]`);
				keys.scrollLeft = Math.max(0, (button?.offsetLeft ?? 0) - 20);
			}, name);
	for (const name of ['Left', 'Down', 'Up', 'Right', 'Enter']) {
		await moveTo(name);
		await key(page, name).tap();
		// One at a time: the pane gets them in the order they were tapped.
		await expect.poll(async () => (await received(page)).keys.at(-1)?.key).toBe(name);
	}
	expect((await received(page)).keys).toEqual(
		['Escape', 'Tab', 'BTab', 'C-c', 'Left', 'Down', 'Up', 'Right', 'Enter'].map((name) => ({
			thread: IDLE,
			key: name
		}))
	);

	// The text keys type at the caret; nothing is sent.
	await box(page).fill('ab');
	await box(page).evaluate((input: HTMLInputElement) => input.setSelectionRange(1, 1));
	for (const name of ['Tilde', 'Pipe', 'Dash']) {
		await moveTo(name);
		await key(page, name).tap();
	}
	await expect(box(page)).toHaveValue('a~|-b');
	await expect(box(page)).toBeFocused();
	await box(page).fill('');
	await moveTo('Slash');
	await key(page, 'Slash').tap();
	await expect(box(page)).toHaveValue('/');
	await expect(slash(page)).toBeVisible();
	expect((await received(page)).keys).toHaveLength(9);
});

test('Ctrl is sticky: the next letter is a control key', async ({ page }) => {
	await open(page, IDLE, ['replies', 'keyBar']);
	const ctrl = key(page, 'Control');
	await expect(ctrl).toHaveAttribute('aria-pressed', 'false');
	await ctrl.tap();
	await expect(ctrl).toHaveAttribute('aria-pressed', 'true');
	await expect(ctrl).toHaveCSS('background-color', 'rgb(50, 145, 255)');
	// The letter comes from the keyboard: the box has the focus.
	await expect(box(page)).toBeFocused();
	await shot(page, 'keybar-ctrl');

	// Not a letter: it is text, nothing is sent, and Ctrl is used up.
	await page.keyboard.type('1');
	await expect(box(page)).toHaveValue('1');
	await expect(ctrl).toHaveAttribute('aria-pressed', 'false');
	await page.keyboard.type('x');
	await expect(box(page)).toHaveValue('1x');
	await box(page).fill('1');
	expect((await received(page)).keys).toEqual([]);

	await ctrl.tap();
	await page.keyboard.type('r');
	await expect(ctrl).toHaveAttribute('aria-pressed', 'false');
	await expect(box(page)).toHaveValue('1');
	await expect
		.poll(async () => (await received(page)).keys)
		.toEqual([{ thread: IDLE, key: 'C-r' }]);

	// Off again: letters are text.
	await page.keyboard.type('r');
	await expect(box(page)).toHaveValue('1r');

	// A second tap switches it off without sending anything.
	await ctrl.tap();
	await expect(ctrl).toHaveAttribute('aria-pressed', 'true');
	await ctrl.tap();
	await expect(ctrl).toHaveAttribute('aria-pressed', 'false');
	await page.keyboard.type('D');
	await expect(box(page)).toHaveValue('1rD');
	expect((await received(page)).keys).toHaveLength(1);

	await ctrl.tap();
	await page.keyboard.type('D');
	await expect.poll(async () => (await received(page)).keys.at(-1)?.key).toBe('C-d');
});

test('the bar sits exactly on the on-screen keyboard', async ({ page }) => {
	await open(page, IDLE, ['replies', 'keyBar']);
	const app = page.locator('[data-app]');
	const dock = page.locator('[data-dock]');
	const before = await dock.boundingBox();
	// The keyboard covers the page without resizing it: only the visual viewport shrinks.
	await page.evaluate(() => {
		const viewport = window.visualViewport as VisualViewport;
		Object.defineProperty(viewport, 'height', { configurable: true, get: () => 508 });
		viewport.dispatchEvent(new Event('resize'));
	});
	await expect(app).toHaveAttribute('data-kb', '');
	const composer = await page.locator('[data-compose]').boundingBox();
	const bar = await keybar(page).boundingBox();
	// On the keyboard: no gap under the box, and nothing under the keyboard.
	expect(Math.abs((composer?.y ?? 0) + (composer?.height ?? 0) - 508)).toBeLessThanOrEqual(1);
	expect((bar?.y ?? 0) + (bar?.height ?? 0)).toBeLessThanOrEqual(composer?.y ?? 0);
	// The chat above still ends on screen, above the bar.
	const chat = await page.locator('[data-view="chat"]').boundingBox();
	expect((chat?.y ?? 0) + (chat?.height ?? 0)).toBeLessThanOrEqual(bar?.y ?? 0);

	await page.evaluate(() => {
		const viewport = window.visualViewport as VisualViewport;
		Object.defineProperty(viewport, 'height', { configurable: true, get: () => 844 });
		viewport.dispatchEvent(new Event('resize'));
	});
	await expect(app).not.toHaveAttribute('data-kb', '');
	expect(await dock.boundingBox()).toEqual(before);
});
test('slash: the list filters as you type and a tap fills the box', async ({ page }) => {
	await open(page, IDLE, ['replies', 'keyBar']);
	await expect(slash(page)).toHaveCount(0);
	await box(page).tap();
	await page.keyboard.type('/');
	await expect(slash(page).getByRole('option')).toHaveCount(7);
	await page.keyboard.type('co');
	await expect(slash(page).locator('b')).toHaveText(['/compact', '/commit', '/code-review']);
	await expect(slash(page).getByRole('option').nth(1)).toContainText('Create a git commit');
	for (const row of await slash(page).getByRole('option').all())
		expect((await row.boundingBox())?.height).toBeGreaterThanOrEqual(44);
	// Above the key bar, which is above the box.
	const list = await slash(page).boundingBox();
	const bar = await keybar(page).boundingBox();
	expect((list?.y ?? 0) + (list?.height ?? 0)).toBeLessThanOrEqual(bar?.y ?? 0);
	await shot(page, 'slash');

	// A name in the middle matches too, after the ones that start with it.
	await box(page).fill('/review');
	await expect(slash(page).locator('b')).toHaveText([
		'/review',
		'/code-review',
		'/security-review'
	]);

	await box(page).fill('/com');
	await slash(page).getByRole('option', { name: '/commit' }).tap();
	await expect(box(page)).toHaveValue('/commit ');
	await expect(box(page)).toBeFocused();
	await expect(slash(page)).toHaveCount(0);

	// Asked for once per thread, however often the list opens.
	await box(page).fill('/');
	await expect(slash(page)).toBeVisible();
	await box(page).fill('/zz');
	await expect(slash(page)).toHaveCount(0);
	expect((await received(page)).commandFetches).toBe(1);
});

test('a permission card is answered with its first option', async ({ page }) => {
	await open(page, PERMISSION, ['replies', 'keyBar']);
	await expect(card(page)).toHaveAttribute('data-kind', 'permission');
	await expect(card(page).locator('h3')).toHaveText('Bash command');
	await expect(card(page).locator('h3')).toHaveCSS('color', 'rgb(248, 81, 73)');
	await expect(card(page).locator('pre')).toHaveText(
		'pnpm exec playwright test tests/checkout.spec.ts'
	);
	await expect(card(page).locator('.q')).toHaveText('Do you want to proceed?');
	const options = card(page).locator('button[data-option]');
	await expect(options).toHaveCount(3);
	await expect(options.nth(0)).toHaveText(/Yes\s*1/);
	await expect(options.nth(2)).toHaveText(/No, and tell Claude what to do differently\s*3/);
	// Only the first one of a permission card has the accent.
	await expect(options.nth(0)).toHaveCSS('background-color', 'rgb(50, 145, 255)');
	await expect(options.nth(1)).not.toHaveCSS('background-color', 'rgb(50, 145, 255)');
	for (const option of await options.all())
		expect((await option.boundingBox())?.height).toBeGreaterThanOrEqual(44);
	// The card is the end of the chat, and it is on screen.
	await expect(card(page)).toBeInViewport({ ratio: 1 });
	// The thread itself needs you: no Next bar. Free text is refused while it waits.
	await expect(nextBar(page)).toHaveCount(0);
	await box(page).fill('x');
	await expect(sendButton(page)).toBeDisabled();
	await box(page).fill('');
	await shot(page, 'permission-card');

	const sent = page.waitForRequest((request) => request.url().endsWith('/answer'));
	await options.nth(0).tap();
	const request = await sent;
	expect(request.headers()['x-muxmaestro']).toBe('1');
	const body = request.postDataJSON() as { prompt: string; option: number };
	expect(body.option).toBe(1);

	await expect(card(page)).toHaveCount(0);
	await expect(page.locator('.tbar .title span')).toContainText('running');
	expect((await received(page)).answers).toEqual([
		{ thread: PERMISSION, prompt: body.prompt, option: 1 }
	]);
});

test('a question card shows in the terminal view and is answered', async ({ page }) => {
	await open(page, QUESTION, ['replies', 'keyBar']);
	await expect(card(page)).toHaveAttribute('data-kind', 'question');
	await expect(card(page).locator('.q')).toHaveText('Which rule should a plan downgrade use?');
	await expect(card(page).locator('pre')).toHaveCount(0);
	// The Mac sent no heading for it.
	await expect(card(page).locator('h3')).toHaveText('Question');
	const options = card(page).locator('button[data-option]');
	await expect(options).toHaveText([
		/Credit the unused days\s*1/,
		/No credit until renewal\s*2/,
		/Type something else\s*3/
	]);
	// No accent on a question.
	await expect(options.nth(0)).not.toHaveCSS('background-color', 'rgb(50, 145, 255)');
	await card(page).scrollIntoViewIfNeeded();
	await shot(page, 'question-card');

	await options.nth(1).tap();
	await expect(card(page)).toHaveCount(0);
	expect((await received(page)).answers).toMatchObject([{ thread: QUESTION, option: 2 }]);
});

test('buttons are off while an answer is in flight', async ({ page }) => {
	await open(page, PERMISSION, ['replies']);
	let release: () => void = () => {};
	const held = new Promise<void>((done) => (release = done));
	await page.route('**/api/threads/*/answer', async (route) => {
		await held;
		await route.continue();
	});
	const options = card(page).locator('button[data-option]');
	await options.nth(1).tap();
	for (const option of await options.all()) await expect(option).toBeDisabled();
	await expect(options.nth(1)).toHaveAttribute('aria-busy', 'true');
	release();
	await expect(card(page)).toHaveCount(0);
	expect((await received(page)).answers).toMatchObject([{ option: 2 }]);
});

test('a stale card is replaced, and nothing is sent again', async ({ page }) => {
	await open(page, PERMISSION, ['replies']);
	await expect(card(page)).toHaveAttribute('data-kind', 'permission');
	const first = await card(page).getAttribute('data-prompt');
	// The pane moved on, and the phone has not been told.
	await page.request.post(`/__fixture/prompt?id=${PERMISSION}&pid=q-next&kind=question&quiet=1`);

	let answers = 0;
	page.on('request', (request) => {
		if (request.url().endsWith('/answer')) answers += 1;
	});
	const refused = page.waitForResponse((response) => response.url().endsWith('/answer'));
	await card(page).getByRole('button').nth(0).tap();
	expect((await refused).status()).toBe(409);

	await expect(card(page)).toHaveAttribute('data-prompt', 'q-next');
	await expect(card(page)).toHaveAttribute('data-kind', 'question');
	expect(first).not.toBe('q-next');
	await page.waitForTimeout(400);
	expect(answers).toBe(1);
	expect((await received(page)).answers).toEqual([]);

	// The new card is answered as itself.
	await card(page).getByRole('button').nth(2).tap();
	await expect(card(page)).toHaveCount(0);
	expect((await received(page)).answers).toEqual([
		{ thread: PERMISSION, prompt: 'q-next', option: 3 }
	]);
});

test('a thread that starts to wait gets its card, and loses it after', async ({ page }) => {
	await open(page, IDLE, ['replies']);
	await expect(card(page)).toHaveCount(0);
	await page.request.post(`/__fixture/wait?id=${IDLE}`);
	await expect(card(page)).toHaveAttribute('data-kind', 'permission');
	await expect(card(page)).toBeInViewport({ ratio: 1 });
	// Answered on the Mac: the card goes with the status.
	await page.request.post(`/__fixture/status?id=${IDLE}&value=busy`);
	await expect(card(page)).toHaveCount(0);
});

test('Next opens the thread that has waited longest', async ({ page }) => {
	await open(page, IDLE, ['replies', 'keyBar']);
	await expect(nextBar(page)).toHaveText(/Next\s+billing · proration\s*›/);
	expect((await nextBar(page).boundingBox())?.height).toBeGreaterThanOrEqual(44);
	const bar = await keybar(page).boundingBox();
	const next = await nextBar(page).boundingBox();
	expect((next?.y ?? 0) + (next?.height ?? 0)).toBeLessThanOrEqual(bar?.y ?? 0);
	await shot(page, 'next-bar');

	await nextBar(page).tap();
	await expect(page).toHaveURL(/\/t\/devbox(:|%3A)2$/);
	await expect(page.locator('.tbar .title b')).toHaveText('billing · proration');
	// This one waits itself: there is no bar, there is its card.
	await expect(nextBar(page)).toHaveCount(0);
	await expect(card(page)).toHaveAttribute('data-kind', 'question');

	// Answered: the bar names the other one.
	await card(page).getByRole('button').nth(0).tap();
	await expect(nextBar(page)).toHaveText(/Next\s+acme-app · checkout-fix/);
});

test('with the features off, the thread shows none of this', async ({ page }) => {
	await open(page, PERMISSION, []);
	await expect(page.locator('.u').first()).toBeVisible();
	await page.waitForTimeout(400);
	// The reply box holds its place, switched off; nothing else of the bar shows.
	await expect(offBox(page)).toBeDisabled();
	await expect(box(page)).toHaveCount(0);
	await expect(keybar(page)).toHaveCount(0);
	await expect(card(page)).toHaveCount(0);
	await expect(nextBar(page)).toHaveCount(0);
	await expect(page.getByRole('button', { name: 'Attach' })).toBeDisabled();
	await expect(voiceControls(page)).toHaveCount(0);

	// Each switch shows only its own controls, as soon as the Mac flips it.
	await page.request.post('/__fixture/capability?name=keyBar&on=1');
	await expect(keybar(page)).toBeVisible();
	await expect(box(page)).toHaveCount(0);
	// The keys answer the prompt, so the card shows what they would answer: read-only.
	await expect(card(page)).toHaveAttribute('data-readonly', '');
	// With no text box there is nothing to type into: only the pane's keys.
	await expect(keybar(page).locator('.keys button')).toHaveCount(9);
	await expect(page.getByRole('button', { name: 'Hide keyboard' })).toHaveCount(0);

	// Upload and voice both need a reply box to sit in.
	await page.request.post('/__fixture/capability?name=upload&on=1');
	await page.request.post('/__fixture/capability?name=voice&on=1');
	await page.waitForTimeout(300);
	await expect(page.getByRole('button', { name: 'Attach' })).toBeDisabled();
	await expect(voiceControls(page)).toHaveCount(0);

	await page.request.post('/__fixture/capability?name=replies&on=1');
	await expect(box(page)).toBeVisible();
	await expect(card(page)).not.toHaveAttribute('data-readonly', '');
	await expect(card(page).locator('button[data-option]')).toHaveCount(3);
	await expect(page.getByRole('button', { name: 'Attach' })).not.toHaveAttribute('aria-disabled');
	await expect(voiceControls(page)).toBeVisible();
	await expect(keybar(page).locator('.keys button')).toHaveCount(14);

	await page.request.post('/__fixture/capability?name=upload&on=0');
	await expect(page.getByRole('button', { name: 'Attach' })).toHaveAttribute(
		'aria-disabled',
		'true'
	);
	await page.request.post('/__fixture/capability?name=voice&on=0');
	await expect(voiceControls(page)).toHaveCount(0);
	await page.request.post('/__fixture/capability?name=keyBar&on=0');
	await expect(keybar(page)).toHaveCount(0);
	await expect(box(page)).toBeVisible();
	await page.request.post('/__fixture/capability?name=replies&on=0');
	await expect(offBox(page)).toBeDisabled();
	await expect(box(page)).toHaveCount(0);
	await expect(card(page)).toHaveCount(0);
});

test('nothing moves when the live data lands', async ({ page }) => {
	await open(page, IDLE, ['replies', 'keyBar', 'upload']);
	const places = async (): Promise<unknown[]> => [
		await box(page).boundingBox(),
		await keybar(page).boundingBox(),
		await nextBar(page).boundingBox()
	];
	const before = await places();
	// The same lists again, and a new line in the chat.
	await page.request.post(`/__fixture/say?id=${IDLE}&text=One%20more%20line`);
	await expect(page.locator('.a').last()).toHaveText('One more line');
	expect(await places()).toEqual(before);
	// Typing moves nothing in the box's row. Send is an icon: the box takes the room Talk had.
	const empty = (await box(page).boundingBox())!;
	await box(page).fill('hello');
	const typed = (await box(page).boundingBox())!;
	expect({ ...typed, width: empty.width }).toEqual(empty);
	expect(typed.width).toBeGreaterThan(empty.width);
	expect((await places()).slice(1)).toEqual(before.slice(1));
});

test('voice into a thread: the take shows as your line and the reply streams in', async ({
	page
}) => {
	await fakeMic(page);
	await open(
		page,
		IDLE,
		['replies', 'keyBar', 'voice'],
		['/__fixture/voice?heard=run%20the%20contrast%20audit&delay=300']
	);
	const primary = page.locator('[data-primary]');
	const status = page.locator('[data-voice-status]');
	await expect(primary).toHaveText('Talk');
	await expect(status).toHaveCount(0);
	const boxBefore = await box(page).boundingBox();

	await primary.click();
	await expect(primary).toHaveText('↑ Submit');
	await page.evaluate(() => window.__mic.speak(true));
	await page.waitForTimeout(600);
	await page.evaluate(() => window.__mic.speak(false));
	// The button changed; the text box did not move.
	expect(await box(page).boundingBox()).toEqual(boxBefore);

	const sent = page.waitForRequest((request) => request.url().includes('/api/voice?'));
	await primary.click();
	const request = await sent;
	expect(new URL(request.url()).search).toBe('?target=localhost%3A7&speaker=1');
	expect(request.headers()['x-muxmaestro']).toBe('1');
	expect(request.headers()['content-type']).toBe('audio/wav');

	await expect(status).toHaveText('Thinking…');
	await expect(page.locator('.u').last()).toHaveText('run the contrast audit');
	await shot(page, 'thread-voice');
	await expect(page.locator('.a').last()).toHaveText(
		'Done: run the contrast audit. 2 files changed, tests pass.'
	);
	await expect(status).toHaveCount(0, { timeout: 8000 });
	// Drawn once: the live lines gave way to the chat's own.
	await expect(page.locator('.u', { hasText: 'run the contrast audit' })).toHaveCount(1);
	await expect(page.locator('.a', { hasText: 'Done: run the contrast audit' })).toHaveCount(1);
	await expect(page.locator('[data-live]')).toHaveCount(0);
	expect((await received(page)).texts).toEqual([
		{ thread: IDLE, text: 'run the contrast audit', spoken: true }
	]);

	// With text in the box the button sends it.
	await box(page).fill('thanks');
	await expect(sendButton(page)).toBeEnabled();
});

test('a take into a busy thread is refused before it starts', async ({ page }) => {
	await fakeMic(page);
	await open(page, BUSY, ['replies', 'voice']);
	const primary = page.locator('[data-primary]');
	await primary.click();
	await page.evaluate(() => window.__mic.speak(true));
	await page.waitForTimeout(500);
	await page.evaluate(() => window.__mic.speak(false));
	await primary.click();
	await expect(page.locator('[data-voice-status]')).toHaveText('search is running a turn');
	await expect(primary).toHaveText('Talk');
	expect((await received(page)).texts).toEqual([]);
});

test('Ctrl is used up by a key of the bar, and switches off by itself', async ({ page }) => {
	await page.clock.install();
	await open(page, IDLE, ['replies', 'keyBar']);
	const ctrl = key(page, 'Control');

	// A key of the bar is one key too: it goes as itself.
	await ctrl.tap();
	await expect(ctrl).toHaveAttribute('aria-pressed', 'true');
	await key(page, 'Tab').tap();
	await expect(ctrl).toHaveAttribute('aria-pressed', 'false');
	await expect
		.poll(async () => (await received(page)).keys)
		.toEqual([{ thread: IDLE, key: 'Tab' }]);

	// So is Backspace.
	await box(page).fill('ab');
	await ctrl.tap();
	await page.keyboard.press('Backspace');
	await expect(ctrl).toHaveAttribute('aria-pressed', 'false');
	await expect(box(page)).toHaveValue('a');

	// With no key at all it holds for five seconds.
	await ctrl.tap();
	await page.clock.fastForward(4500);
	await expect(ctrl).toHaveAttribute('aria-pressed', 'true');
	await page.clock.fastForward(600);
	await expect(ctrl).toHaveAttribute('aria-pressed', 'false');
	await page.keyboard.type('c');
	await expect(box(page)).toHaveValue('ac');

	// A tap that switches it off also stops the clock: the next hold is a full one.
	await ctrl.tap();
	await page.clock.fastForward(4000);
	await ctrl.tap();
	await ctrl.tap();
	await page.clock.fastForward(4000);
	await expect(ctrl).toHaveAttribute('aria-pressed', 'true');
	expect((await received(page)).keys).toHaveLength(1);
});

test('key presses go one at a time, in order', async ({ page }) => {
	await open(page, IDLE, ['keyBar']);
	const refused: number[] = [];
	page.on('response', (response) => {
		if (response.url().endsWith('/key') && !response.ok()) refused.push(response.status());
	});
	// Five taps before the first one is answered.
	await keybar(page).evaluate((bar) => {
		for (const label of ['Up', 'Up', 'Down', 'Enter', 'Escape'])
			bar.querySelector<HTMLElement>(`[aria-label="${label}"]`)?.click();
	});
	await expect.poll(async () => (await received(page)).keys.length).toBe(5);
	expect((await received(page)).keys.map((sent) => sent.key)).toEqual([
		'Up',
		'Up',
		'Down',
		'Enter',
		'Escape'
	]);
	expect(refused).toEqual([]);

	// More than the queue holds: the extra taps are dropped, none is refused.
	await keybar(page).evaluate((bar) => {
		for (let i = 0; i < 30; i += 1) bar.querySelector<HTMLElement>('[aria-label="Tab"]')?.click();
	});
	await page.waitForTimeout(1200);
	const count = (await received(page)).keys.length;
	expect(count).toBeGreaterThan(5);
	expect(count).toBeLessThanOrEqual(5 + 9);
	expect(refused).toEqual([]);
});

test('a reply the pane gave back stays in the box', async ({ page }) => {
	await open(page, IDLE, ['replies']);
	await page.request.post('/__fixture/not-sent?cleared=1&reason=busy');
	await box(page).fill('ship it');
	await sendButton(page).click();
	await expect(note(page)).toHaveText('dark-mode did not take the reply');
	await expect(box(page)).toHaveValue('ship it');
	const got = await received(page);
	expect(got.texts).toEqual([]);
	expect(got.left).toEqual([]);

	// Sent again, it goes.
	await sendButton(page).click();
	await expect(box(page)).toHaveValue('');
	expect((await received(page)).texts).toEqual([{ thread: IDLE, text: 'ship it' }]);
});

test('a reply left in the pane empties the box, and is not sent twice', async ({ page }) => {
	await open(page, IDLE, ['replies']);
	await page.request.post('/__fixture/not-sent?cleared=0&reason=busy');
	let posts = 0;
	page.on('request', (request) => {
		if (request.url().endsWith('/text')) posts += 1;
	});
	await box(page).fill('ship it');
	await sendButton(page).click();
	await expect(note(page)).toHaveText('Left in the pane');
	await expect(box(page)).toHaveValue('');
	expect((await received(page)).left).toEqual([{ thread: IDLE, text: 'ship it' }]);

	// Send has nothing to send: neither the button nor Enter posts the old text.
	await expect(idlePill(page)).toBeDisabled();
	await submit(page);
	await page.waitForTimeout(300);
	expect(posts).toBe(1);

	await box(page).fill('and then deploy');
	await sendButton(page).click();
	await expect(box(page)).toHaveValue('');
	await expect(page.locator('.u').last()).toHaveText('and then deploy');
	expect((await received(page)).texts).toEqual([{ thread: IDLE, text: 'and then deploy' }]);
	expect(posts).toBe(2);
});

test('a pane with no input box refuses text, and the draft stays', async ({ page }) => {
	await open(page, IDLE, ['replies'], [`/__fixture/no-input?id=${IDLE}`]);
	await box(page).fill('ship it');
	await sendButton(page).click();
	await expect(note(page)).toHaveText('Thread shows no input box');
	await expect(box(page)).toHaveValue('ship it');
	expect((await received(page)).texts).toEqual([]);
});
test('a key on a waiting thread names the prompt the phone shows', async ({ page }) => {
	await open(page, PERMISSION, ['replies', 'keyBar']);
	const shown = await card(page).getAttribute('data-prompt');
	expect(shown).toBeTruthy();
	const sent = page.waitForRequest((request) => request.url().endsWith('/key'));
	await key(page, 'Enter').tap();
	expect((await sent).postDataJSON()).toEqual({ key: 'Enter', prompt: shown });
	await expect
		.poll(async () => (await received(page)).keys)
		.toEqual([{ thread: PERMISSION, key: 'Enter', prompt: shown }]);
});

test('a key aimed at a prompt that changed is not sent again', async ({ page }) => {
	await open(page, PERMISSION, ['replies', 'keyBar']);
	await expect(card(page)).toHaveAttribute('data-kind', 'permission');
	// The pane moved on, and the phone has not been told.
	await page.request.post(`/__fixture/prompt?id=${PERMISSION}&pid=q-next&kind=question&quiet=1`);
	let posts = 0;
	page.on('request', (request) => {
		if (request.url().endsWith('/key')) posts += 1;
	});
	const refused = page.waitForResponse((response) => response.url().endsWith('/key'));
	// Two taps: the one behind the refused key is dropped with it.
	await keybar(page).evaluate((bar) => {
		for (const label of ['Enter', 'Down'])
			bar.querySelector<HTMLElement>(`[aria-label="${label}"]`)?.click();
	});
	expect((await refused).status()).toBe(409);
	await expect(note(page)).toHaveText('Prompt changed');
	await expect(card(page)).toHaveAttribute('data-prompt', 'q-next');
	await expect(card(page)).toHaveAttribute('data-kind', 'question');
	await page.waitForTimeout(400);
	expect(posts).toBe(1);
	expect((await received(page)).keys).toEqual([]);

	// Tapped again, it names the new prompt.
	await key(page, 'Enter').tap();
	await expect
		.poll(async () => (await received(page)).keys)
		.toEqual([{ thread: PERMISSION, key: 'Enter', prompt: 'q-next' }]);
	await expect(note(page)).toHaveCount(0);
});

test('a wait with no readable choices: a small card, and Enter is refused once', async ({
	page
}) => {
	await open(page, PERMISSION, ['replies', 'keyBar']);
	await expect(card(page)).toHaveAttribute('data-kind', 'permission');
	await page.request.post(`/__fixture/prompt?id=${PERMISSION}&pid=bare-1&bare=1`);
	await expect(card(page)).toHaveAttribute('data-kind', 'bare');
	await expect(card(page)).toHaveAttribute('data-prompt', 'bare-1');
	await expect(card(page).locator('h3')).toHaveText('Waiting on a prompt');
	// The heading and the way to the terminal, nothing else.
	await expect(card(page).locator('pre, .q, [data-option]')).toHaveCount(0);
	const show = card(page).getByRole('button', { name: 'Show terminal' });
	await expect(show).toHaveText(['Show terminal']);
	// The way to the terminal, and the way out of the prompt. Nothing else.
	await expect(card(page).getByRole('button')).toHaveText(['Show terminal', 'Cancel']);
	expect((await show.boundingBox())?.height).toBeGreaterThanOrEqual(44);
	await expect(card(page)).toBeInViewport({ ratio: 1 });
	await shot(page, 'bare-card');

	// Nobody can read what Enter would pick: refused, said, and not sent again.
	let posts = 0;
	page.on('request', (request) => {
		if (request.url().endsWith('/key')) posts += 1;
	});
	const refused = page.waitForResponse((response) => response.url().endsWith('/key'));
	await keybar(page).evaluate((bar) => {
		for (const label of ['Enter', 'Down'])
			bar.querySelector<HTMLElement>(`[aria-label="${label}"]`)?.click();
	});
	const response = await refused;
	expect(response.status()).toBe(409);
	expect(((await response.json()) as { error: string }).error).toBe('unseen');
	await expect(note(page)).toHaveText('Open the terminal to answer');
	await page.waitForTimeout(400);
	// The key that waited behind it went nowhere.
	expect(posts).toBe(1);
	expect((await received(page)).keys).toEqual([]);

	// Escape is safe at any prompt: it goes, with the id of the card on screen.
	await key(page, 'Escape').tap();
	await expect
		.poll(async () => (await received(page)).keys)
		.toEqual([{ thread: PERMISSION, key: 'Escape', prompt: 'bare-1' }]);

	await show.tap();
	await expect(page.locator('[data-tab="main"]')).toHaveText(/Terminal\s*⇄/);
	await expect(card(page).getByRole('button', { name: 'Show terminal' })).toHaveCount(0);
});

test('a prompt the status does not tell of shows after the refusal', async ({ page }) => {
	await open(page, IDLE, ['replies', 'keyBar']);
	await expect(card(page)).toHaveCount(0);
	// The pane asks, and the thread list still says idle.
	await page.request.post(`/__fixture/prompt?id=${IDLE}&pid=hidden-1&quiet=1`);
	await box(page).fill('ship it');
	await sendButton(page).click();
	await expect(note(page)).toHaveText('dark-mode is waiting on a prompt');
	await expect(box(page)).toHaveValue('ship it');
	await expect(card(page)).toHaveAttribute('data-prompt', 'hidden-1');
	await expect(page.locator('.tbar .title span')).toContainText('idle');
	// With the card up, free text waits.
	await expect(sendButton(page)).toBeDisabled();

	await card(page).getByRole('button').nth(0).tap();
	await expect(card(page)).toHaveCount(0);
	expect((await received(page)).answers).toEqual([{ thread: IDLE, prompt: 'hidden-1', option: 1 }]);
});

test('a truncated card says so and opens the terminal', async ({ page }) => {
	await open(page, PERMISSION, ['replies', 'keyBar']);
	await expect(card(page)).toBeVisible();
	await expect(card(page).getByRole('button', { name: 'Show terminal' })).toHaveCount(0);
	await page.request.post(`/__fixture/prompt?id=${PERMISSION}&pid=long-1&truncated=1`);
	await expect(card(page)).toHaveAttribute('data-prompt', 'long-1');
	await expect(card(page).locator('pre')).toHaveText(/^kubectl rollout restart .*…$/);
	await expect(card(page).locator('pre')).not.toContainText('kubectl get pods');
	await expect(card(page).locator('[data-more]')).toHaveText('…');
	const show = card(page).getByRole('button', { name: 'Show terminal' });
	expect((await show.boundingBox())?.height).toBeGreaterThanOrEqual(44);
	// The answers are still there.
	await expect(card(page).getByRole('button')).toHaveCount(5);
	await show.scrollIntoViewIfNeeded();
	await shot(page, 'truncated-card');

	await show.tap();
	await expect(page.locator('[data-tab="main"]')).toHaveText(/Terminal\s*⇄/);
	await expect(page.locator('.screen')).toContainText('kubectl get pods -n staging');
	// The terminal is showing: the card has nothing more to open.
	await expect(card(page)).toBeVisible();
	await expect(show).toHaveCount(0);
});

test('with the key bar alone the card is read-only, and the keys name it', async ({ page }) => {
	await open(page, PERMISSION, ['keyBar']);
	await expect(card(page)).toHaveAttribute('data-readonly', '');
	await expect(card(page).locator('h3')).toHaveText('Bash command');
	await expect(card(page).locator('pre')).toHaveText(
		'pnpm exec playwright test tests/checkout.spec.ts'
	);
	await expect(card(page).locator('.q')).toHaveText('Do you want to proceed?');
	// The answers are listed with their numbers, and none of them is a control.
	await expect(card(page).locator('[data-option]')).toHaveText([
		/Yes\s*1/,
		/Yes, and don’t ask again for pnpm exec\s*2/,
		/No, and tell Claude what to do differently\s*3/
	]);
	await expect(card(page).getByRole('button')).toHaveCount(0);
	// The row Enter takes is marked here too.
	await expect(card(page).locator('[aria-current="true"]')).toHaveText(/^❯\s*Yes\s*1$/);
	await expect(card(page).locator('[data-option]').first()).not.toHaveCSS(
		'background-color',
		'rgb(50, 145, 255)'
	);
	await expect(box(page)).toHaveCount(0);
	await expect(card(page)).toBeInViewport({ ratio: 1 });
	await shot(page, 'readonly-card');

	// A tap on an answer does nothing.
	let answers = 0;
	page.on('request', (request) => {
		if (request.url().endsWith('/answer')) answers += 1;
	});
	await card(page).locator('[data-option]').first().tap();
	await page.waitForTimeout(200);
	expect(answers).toBe(0);

	const shown = await card(page).getAttribute('data-prompt');
	const sent = page.waitForRequest((request) => request.url().endsWith('/key'));
	await key(page, 'Enter').tap();
	expect((await sent).postDataJSON()).toEqual({ key: 'Enter', prompt: shown });
	await expect
		.poll(async () => (await received(page)).keys)
		.toEqual([{ thread: PERMISSION, key: 'Enter', prompt: shown }]);

	// A long command still has its way to the terminal.
	await page.request.post(`/__fixture/prompt?id=${PERMISSION}&pid=long-2&truncated=1`);
	await expect(card(page)).toHaveAttribute('data-prompt', 'long-2');
	await expect(card(page).getByRole('button')).toHaveText(['Show terminal']);
	await card(page).getByRole('button').tap();
	await expect(page.locator('.screen')).toContainText('kubectl get pods -n staging');
});

test('a prompt that came up after the paste: the box empties and the card shows', async ({
	page
}) => {
	await open(page, IDLE, ['replies']);
	// The fixture answers as the Mac does: at a prompt it sends no keys, so nothing is cleared.
	await page.request.post('/__fixture/not-sent?cleared=1&reason=waiting');
	let posts = 0;
	page.on('request', (request) => {
		if (request.url().endsWith('/text')) posts += 1;
	});
	await box(page).fill('ship it');
	const refused = page.waitForResponse((response) => response.url().endsWith('/text'));
	await sendButton(page).click();
	expect(await (await refused).json()).toMatchObject({
		error: 'not_sent',
		reason: 'waiting',
		cleared: false
	});
	await expect(note(page)).toHaveText('Left in the pane');
	await expect(box(page)).toHaveValue('');
	await expect(card(page)).toHaveAttribute('data-kind', 'permission');
	// Nothing to send, by the pill or by Enter.
	await expect(idlePill(page)).toBeDisabled();
	await submit(page);
	await page.waitForTimeout(300);
	expect(posts).toBe(1);
	const got = await received(page);
	expect(got.texts).toEqual([]);
	expect(got.left).toEqual([{ thread: IDLE, text: 'ship it' }]);
});

test('the prompt is closed to a phone with both switches off', async ({ page }) => {
	await reset(page);
	const get = (): ReturnType<typeof page.request.get> =>
		page.request.get(`/api/threads/${encodeURIComponent(PERMISSION)}/prompt`, {
			headers: TOKEN_HEADER
		});
	expect((await get()).status()).toBe(403);
	await page.request.post('/__fixture/capability?name=keyBar&on=1');
	expect((await get()).status()).toBe(200);
	await page.request.post('/__fixture/capability?name=keyBar&on=0');
	await page.request.post('/__fixture/capability?name=replies&on=1');
	expect((await get()).status()).toBe(200);
});

test('the text size and the terminal view work with the bar and the card in place', async ({
	page
}) => {
	await open(page, PERMISSION, ['replies', 'keyBar']);
	const px = (selector: string): Promise<number> =>
		page
			.locator(selector)
			.first()
			.evaluate((el) => parseFloat(getComputedStyle(el).fontSize));
	// The card is chat text: it grows with it, heading and command too.
	const before = { q: await px('[data-prompt] .q'), h3: await px('[data-prompt] h3') };
	// The size is set by a pinch on the terminal text; the chat follows it.
	await page.locator('[data-tab="main"]').tap();
	await expect(page.locator('.screen')).toBeVisible();
	await twoFingers(
		page,
		[
			[150, 300],
			[250, 300]
		],
		[
			[120, 300],
			[280, 300]
		]
	);
	await page.locator('[data-tab="main"]').tap();
	await expect.poll(() => px('[data-prompt] .q')).toBeGreaterThan(before.q);
	expect(await px('[data-prompt] h3')).toBeGreaterThan(before.h3);
	expect(await px('[data-prompt] .q')).toBe(await px('.a'));
	// The bar below keeps its own size.
	expect(await px('[data-keybar] .keys button')).toBe(11.5);

	// In the terminal the coloured text, the card and the bar stack: none covers another.
	await page.locator('[data-tab="main"]').tap();
	await expect(page.locator('.screen')).toContainText('pnpm exec playwright test');
	await expect(card(page)).toBeVisible();
	const view = await page.locator('[data-view="terminal"]').boundingBox();
	const dock = await page.locator('[data-dock]').boundingBox();
	expect((view?.y ?? 0) + (view?.height ?? 0)).toBeLessThanOrEqual(dock?.y ?? 0);
	// The card is answered from the terminal view too.
	await card(page).getByRole('button').nth(0).tap();
	await expect(card(page)).toHaveCount(0);
	expect((await received(page)).answers).toMatchObject([{ thread: PERMISSION, option: 1 }]);
});

test('the key bar scrolls sideways without moving the page or the drawer', async ({ page }) => {
	await open(page, 'devbox:5', ['replies', 'keyBar']);
	await expect(page.locator('.screen')).toBeVisible();
	const keys = keybar(page).locator('.keys');
	const at = await keys.boundingBox();
	const y = (at?.y ?? 0) + (at?.height ?? 0) / 2;
	const textSize = await page.locator('.screen').evaluate((el) => getComputedStyle(el).fontSize);
	await touchDrag(page, [300, y], [80, y]);
	expect(await keys.evaluate((el) => el.scrollLeft)).toBeGreaterThan(100);
	// Not a page swipe, not the drawer, not a pinch.
	await expect(page.locator('[data-drawer]')).toBeHidden();
	expect(await page.locator('.screen').evaluate((el) => getComputedStyle(el).fontSize)).toBe(
		textSize
	);
	expect(await page.locator('.screen').evaluate((el) => el.scrollLeft)).toBe(0);
});

const current = (page: Page): Locator => card(page).locator('[aria-current="true"]');

test('the card marks the row Enter takes, and follows the arrows', async ({ page }) => {
	await open(page, PERMISSION, ['replies', 'keyBar']);
	const options = card(page).locator('[data-option]');
	await expect(current(page)).toHaveCount(1);
	await expect(current(page)).toHaveAttribute('data-option', '1');
	await expect(current(page)).toHaveText(/^❯\s*Yes\s*1$/);
	await expect(options.nth(0)).toHaveCSS('background-color', 'rgb(50, 145, 255)');
	const first = await card(page).getAttribute('data-prompt');

	await key(page, 'Down').tap();
	// The mark moves, and the accent with it: row 1 no longer looks like what Enter takes.
	await expect(current(page)).toHaveAttribute('data-option', '2');
	await expect(current(page)).toHaveText(/^❯\s*Yes, and don’t ask again for pnpm exec\s*2$/);
	await expect(current(page)).toHaveCSS('border-top-color', 'rgb(50, 145, 255)');
	await expect(options.nth(0)).not.toHaveCSS('background-color', 'rgb(50, 145, 255)');
	await expect(options.nth(0)).not.toContainText('❯');
	const second = await card(page).getAttribute('data-prompt');
	expect(second).not.toBe(first);

	// Enter now names the card that is on screen: the new one.
	await key(page, 'Enter').tap();
	await expect
		.poll(async () => (await received(page)).keys)
		.toEqual([
			{ thread: PERMISSION, key: 'Down', prompt: first },
			{ thread: PERMISSION, key: 'Enter', prompt: second }
		]);
	await expect(note(page)).toHaveCount(0);

	// Back up: the first row is the accent Yes again.
	await key(page, 'Up').tap();
	await expect(current(page)).toHaveAttribute('data-option', '1');
	await expect(card(page)).toHaveAttribute('data-prompt', first ?? '');
	await expect(options.nth(0)).toHaveCSS('background-color', 'rgb(50, 145, 255)');
});

test('Enter tapped before the card caught up names the old card, and is not sent again', async ({
	page
}) => {
	await open(page, PERMISSION, ['replies', 'keyBar']);
	await expect(current(page)).toHaveAttribute('data-option', '1');
	const first = await card(page).getAttribute('data-prompt');
	// The phone learns of the new row only after a while.
	await page.request.post('/__fixture/prompt-delay?ms=700');
	const posted: unknown[] = [];
	const answers: number[] = [];
	page.on('request', (request) => {
		if (request.url().endsWith('/key')) posted.push(request.postDataJSON());
	});
	page.on('response', (response) => {
		if (response.url().endsWith('/key')) answers.push(response.status());
	});
	// Down, and Enter right behind it: the human saw row 1 when Enter was tapped.
	await keybar(page).evaluate((bar) => {
		for (const label of ['Down', 'Enter'])
			bar.querySelector<HTMLElement>(`[aria-label="${label}"]`)?.click();
	});
	await expect.poll(() => answers).toEqual([200, 409]);
	expect(posted).toEqual([
		{ key: 'Down', prompt: first },
		{ key: 'Enter', prompt: first }
	]);
	// At this moment the card has not caught up: Enter went with what was on screen.
	await expect(note(page)).toHaveText('Prompt changed');

	// The card ends on the new selection, and nothing was sent a second time.
	await expect(current(page)).toHaveAttribute('data-option', '2');
	await expect(card(page)).not.toHaveAttribute('data-prompt', first ?? '');
	await page.waitForTimeout(900);
	expect(posted).toHaveLength(2);
	expect((await received(page)).keys).toEqual([{ thread: PERMISSION, key: 'Down', prompt: first }]);

	// Seen now: Enter takes row 2.
	await page.request.post('/__fixture/prompt-delay?ms=0');
	const second = await card(page).getAttribute('data-prompt');
	await key(page, 'Enter').tap();
	await expect
		.poll(async () => (await received(page)).keys.at(-1))
		.toEqual({ thread: PERMISSION, key: 'Enter', prompt: second });
});

test('the read-only card follows the arrows too', async ({ page }) => {
	await open(page, PERMISSION, ['keyBar']);
	await expect(card(page)).toHaveAttribute('data-readonly', '');
	await expect(current(page)).toHaveAttribute('data-option', '1');
	await key(page, 'Down').tap();
	await key(page, 'Down').tap();
	await expect(current(page)).toHaveAttribute('data-option', '3');
	await expect(current(page)).toHaveText(/^❯\s*No, and tell Claude what to do differently\s*3$/);
	await expect(card(page).locator('[aria-current="true"]')).toHaveCount(1);
});

test('Enter on a pane with no input box in sight is refused, and says why', async ({ page }) => {
	await open(page, IDLE, ['keyBar'], [`/__fixture/no-input?id=${IDLE}`]);
	let posts = 0;
	page.on('request', (request) => {
		if (request.url().endsWith('/key')) posts += 1;
	});
	await keybar(page).evaluate((bar) => {
		for (const label of ['Enter', 'Down'])
			bar.querySelector<HTMLElement>(`[aria-label="${label}"]`)?.click();
	});
	// With the key bar alone there is no composer: the bar says it.
	await expect(page.locator('[data-note]')).toHaveText('Thread shows no input box');
	await page.waitForTimeout(400);
	expect(posts).toBe(1);
	expect((await received(page)).keys).toEqual([]);
	// Escape is still taken.
	await key(page, 'Escape').tap();
	await expect
		.poll(async () => (await received(page)).keys)
		.toEqual([{ thread: IDLE, key: 'Escape' }]);
});

test('a scrolled menu lists its rows, says there are more, and opens the terminal', async ({
	page
}) => {
	await open(page, IDLE, ['replies', 'keyBar']);
	await page.request.post(`/__fixture/prompt?id=${IDLE}&pid=menu-1&scrolled=9`);
	await expect(card(page)).toHaveAttribute('data-prompt', 'menu-1');
	const rows = card(page).locator('[data-option]');
	await expect(rows).toHaveText([
		/eu-central\s*4$/,
		/eu-north\s*5$/,
		/ap-south\s*6$/,
		/ap-southeast\s*7$/,
		/ap-northeast\s*8$/,
		/sa-east\s*9$/
	]);
	// The pane's cursor is on the first row it shows, which is not option 1.
	await expect(current(page)).toHaveAttribute('data-option', '4');
	await expect(card(page).locator('[data-rest]')).toHaveText('More choices in the terminal');
	const show = card(page).getByRole('button', { name: 'Show terminal' });
	expect((await show.boundingBox())?.height).toBeGreaterThanOrEqual(44);
	await show.scrollIntoViewIfNeeded();
	await shot(page, 'scrolled-card');

	// A row is answered by its own number, not by its place on the card.
	await rows.nth(2).tap();
	await expect(card(page)).toHaveCount(0);
	expect((await received(page)).answers).toEqual([{ thread: IDLE, prompt: 'menu-1', option: 6 }]);

	// Past 9 the pane has no key: those rows are read, not pressed.
	await page.request.post(`/__fixture/prompt?id=${IDLE}&pid=menu-2&scrolled=12`);
	await expect(card(page)).toHaveAttribute('data-prompt', 'menu-2');
	await expect(rows).toHaveCount(9);
	await expect(card(page).locator('button[data-option]')).toHaveCount(6);
	await expect(card(page).locator('div[data-option]')).toHaveText([
		/ca-central\s*10$/,
		/me-south\s*11$/,
		/af-south\s*12$/
	]);
	let answers = 0;
	page.on('request', (request) => {
		if (request.url().endsWith('/answer')) answers += 1;
	});
	await card(page).locator('div[data-option]').first().tap();
	await page.waitForTimeout(200);
	expect(answers).toBe(0);

	await card(page).getByRole('button', { name: 'Show terminal' }).tap();
	await expect(page.locator('[data-tab="main"]')).toHaveText(/Terminal\s*⇄/);
	await expect(page.locator('.screen')).toContainText('12. af-south');
});

test('Ctrl and m at a prompt nobody can read is refused like Enter, once', async ({ page }) => {
	await open(page, PERMISSION, ['replies', 'keyBar']);
	await page.request.post(`/__fixture/prompt?id=${PERMISSION}&pid=bare-2&bare=1`);
	await expect(card(page)).toHaveAttribute('data-kind', 'bare');
	const posted: unknown[] = [];
	page.on('request', (request) => {
		if (request.url().endsWith('/key')) posted.push(request.postDataJSON());
	});
	const refused = page.waitForResponse((response) => response.url().endsWith('/key'));
	await key(page, 'Control').tap();
	await page.keyboard.type('m');
	const response = await refused;
	expect(response.status()).toBe(409);
	expect(((await response.json()) as { error: string }).error).toBe('unseen');
	await expect(note(page)).toHaveText('Open the terminal to answer');
	await expect(box(page)).toHaveValue('');
	await page.waitForTimeout(400);
	expect(posted).toEqual([{ key: 'C-m', prompt: 'bare-2' }]);
	expect((await received(page)).keys).toEqual([]);
	// The card is still the one the pane shows.
	await expect(card(page)).toHaveAttribute('data-prompt', 'bare-2');
});

test('Sh+Tab on a pane with no input box in sight says why', async ({ page }) => {
	await open(page, IDLE, ['replies', 'keyBar'], [`/__fixture/no-input?id=${IDLE}`]);
	let posts = 0;
	page.on('request', (request) => {
		if (request.url().endsWith('/key')) posts += 1;
	});
	await keybar(page).evaluate((bar) => {
		for (const label of ['Shift Tab', 'Down'])
			bar.querySelector<HTMLElement>(`[aria-label="${label}"]`)?.click();
	});
	await expect(note(page)).toHaveText('Thread shows no input box');
	await page.waitForTimeout(400);
	expect(posts).toBe(1);
	expect((await received(page)).keys).toEqual([]);
	// Tab alone submits nothing: it goes.
	await key(page, 'Tab').tap();
	await expect
		.poll(async () => (await received(page)).keys)
		.toEqual([{ thread: IDLE, key: 'Tab' }]);
});

test('the fixture refuses a digit that is not on the card, and an answer past 9', async ({
	page
}) => {
	await reset(page);
	for (const name of ['replies', 'keyBar'])
		await page.request.post(`/__fixture/capability?name=${name}&on=1`);
	await page.request.post(`/__fixture/prompt?id=${IDLE}&pid=menu-3&scrolled=12`);
	const origin = new URL(test.info().project.use.baseURL ?? '').origin;
	const post = (path: string, data: unknown): Promise<APIResponse> =>
		page.request.post(`/api/threads/${encodeURIComponent(IDLE)}/${path}`, {
			data,
			headers: { ...WRITE, origin }
		});
	const digit = await post('key', { key: '2', prompt: 'menu-3' });
	expect([digit.status(), await digit.json()]).toEqual([
		409,
		{ error: 'no_option', message: 'Not a choice on the card' }
	]);
	expect((await post('key', { key: '5', prompt: 'menu-3' })).status()).toBe(200);
	expect((await post('answer', { prompt: 'menu-3', option: 11 })).status()).toBe(400);
	expect((await post('answer', { prompt: 'menu-3', option: 2 })).status()).toBe(400);
	expect((await post('answer', { prompt: 'menu-3', option: 9 })).status()).toBe(200);
});

test('with replies off the reply box is there, switched off, and posts nothing', async ({
	page
}) => {
	await open(page, IDLE, []);
	const writes: string[] = [];
	page.on('request', (request) => {
		if (request.method() === 'POST' && request.url().includes('/api/')) writes.push(request.url());
	});
	const refusals: string[] = [];
	page.on('response', (response) => {
		if (response.status() === 403) refusals.push(response.url());
	});
	await expect(offBox(page)).toBeVisible();
	await expect(offBox(page)).toBeDisabled();
	await expect(offBox(page)).toHaveAttribute('placeholder', 'Off in MuxMaestro Settings');
	await expect(offBox(page)).toHaveValue('');
	const pill = idlePill(page);
	await expect(pill).toHaveText(['Talk']);
	await expect(pill).toBeDisabled();
	// The label, the dimmed attach button and the pill: no slash list, no voice bar, no key bar, no card.
	await expect(page.locator('[data-compose] > :not([hidden])')).toHaveCount(3);
	await expect(page.getByRole('button', { name: 'Attach' })).toBeDisabled();
	await expect(keybar(page)).toHaveCount(0);
	await expect(slash(page)).toHaveCount(0);
	await expect(nextBar(page)).toHaveCount(0);
	await expect(voiceControls(page)).toHaveCount(0);
	await expect(page.locator('[data-note]')).toHaveCount(0);
	// Readable, not a faded-out box.
	await expect(offBox(page)).toHaveCSS('opacity', '1');
	// It sits on the bottom edge, inside the screen.
	const off = await page.locator('[data-compose]').boundingBox();
	expect((off?.y ?? 0) + (off?.height ?? 0)).toBeLessThanOrEqual(844);
	expect((off?.y ?? 0) + (off?.height ?? 0)).toBeGreaterThan(830);
	await shot(page, 'composer-off');

	// Taps do nothing: no focus, no keyboard, no request.
	await offBox(page).tap({ force: true });
	await pill.tap({ force: true });
	await page.keyboard.type('hello');
	await page.keyboard.press('Enter');
	await page.waitForTimeout(300);
	await expect(offBox(page)).not.toBeFocused();
	await expect(offBox(page)).toHaveValue('');
	expect(writes).toEqual([]);
	// And the phone asked for nothing it is not allowed to have.
	expect(refusals).toEqual([]);
	expect((await received(page)).texts).toEqual([]);

	// The Mac switches replies on: the same box, live, in the same place, with no reload.
	const boxBefore = await offBox(page).boundingBox();
	await page.evaluate(() => ((window as unknown as { __kept: boolean }).__kept = true));
	await page.request.post('/__fixture/capability?name=replies&on=1');
	await expect(box(page)).toBeEnabled();
	await expect(offBox(page)).toHaveCount(0);
	expect(await page.evaluate(() => (window as unknown as { __kept?: boolean }).__kept)).toBe(true);
	const on = await page.locator('[data-compose]').boundingBox();
	const boxAfter = await box(page).boundingBox();
	expect(Math.abs((on?.y ?? 0) - (off?.y ?? 0))).toBeLessThanOrEqual(1);
	expect(Math.abs((on?.height ?? 0) - (off?.height ?? 0))).toBeLessThanOrEqual(1);
	expect(Math.abs((boxAfter?.y ?? 0) - (boxBefore?.y ?? 0))).toBeLessThanOrEqual(1);
	expect(Math.abs((boxAfter?.width ?? 0) - (boxBefore?.width ?? 0))).toBeLessThanOrEqual(1);

	await box(page).fill('ship it');
	await sendButton(page).click();
	await expect(page.locator('.u').last()).toHaveText('ship it');

	// And off again, live.
	await page.request.post('/__fixture/capability?name=replies&on=0');
	await expect(offBox(page)).toBeDisabled();
	await expect(offBox(page)).toHaveValue('');
});

test('the key bar sits above the switched-off reply box', async ({ page }) => {
	await open(page, PERMISSION, ['keyBar']);
	await expect(offBox(page)).toBeDisabled();
	await expect(keybar(page)).toBeVisible();
	const bar = await keybar(page).boundingBox();
	const compose = await page.locator('[data-compose]').boundingBox();
	expect((bar?.y ?? 0) + (bar?.height ?? 0)).toBeLessThanOrEqual(compose?.y ?? 0);
	// The read-only card and the keys work as before.
	await expect(card(page)).toHaveAttribute('data-readonly', '');
	const shown = await card(page).getAttribute('data-prompt');
	await key(page, 'Escape').tap();
	await expect
		.poll(async () => (await received(page)).keys)
		.toEqual([{ thread: PERMISSION, key: 'Escape', prompt: shown }]);
	// The key bar's own refusals are still said, once.
	await page.request.post(`/__fixture/prompt?id=${PERMISSION}&pid=moved-1&quiet=1`);
	await key(page, 'Enter').tap();
	await expect(page.locator('[data-note]')).toHaveText(['Prompt changed']);
});

test('the Maestro home is not a listed thread: it gets no dock and no reply routes', async ({
	page
}) => {
	await reset(page);
	for (const name of ['replies', 'keyBar', 'upload'])
		await page.request.post(`/__fixture/capability?name=${name}&on=1`);
	await forget(page);
	const asked: string[] = [];
	page.on('request', (request) => {
		const path = new URL(request.url()).pathname;
		if (path.startsWith('/api/threads/manager')) asked.push(path);
	});
	await page.goto(pairingLink());
	const ask = page.getByRole('textbox', { name: 'Ask the Maestro' });
	await expect(ask).toBeVisible();
	await expect(page.locator('.a').first()).toBeVisible();
	// Its own text box, and nothing of a thread's reply bar.
	await expect(page.locator('[data-dock]')).toHaveCount(0);
	// The pane's keys only: its text box belongs to the manager's own turns.
	await expect(keybar(page).locator('.keys button')).toHaveCount(9);
	// The manager's text box brings the keyboard up: the strip can put it away.
	await expect(page.getByRole('button', { name: 'Hide keyboard' })).toHaveCount(1);
	await expect(card(page)).toHaveCount(0);
	await expect(nextBar(page)).toHaveCount(0);
	await expect(page.getByRole('button', { name: 'Attach' })).toHaveCount(0);
	await expect(page.locator('form.compose')).toHaveCount(1);
	// Longer than one prompt poll.
	await page.waitForTimeout(3500);
	expect(asked).toEqual([]);
	await shot(page, 'manager-home');

	// A slash is text here: the manager has no command list on the phone.
	await ask.fill('/co');
	await expect(slash(page)).toHaveCount(0);
	expect(asked).toEqual([]);
});

test('the voice status sits above the key strip, and its controls below it', async ({ page }) => {
	await open(page, IDLE, ['replies', 'keyBar', 'voice']);
	const line = page.locator('[data-voice-line]');
	const controls = page.locator('[data-voicebar]');
	// Idle, the voice says nothing: no status line is drawn in either part.
	await expect(page.locator('[data-voice-status]')).toHaveCount(0);
	const top = async (target: Locator): Promise<number> => (await target.boundingBox())?.y ?? 0;
	expect(await top(line)).toBeLessThan(await top(keybar(page)));
	expect(await top(keybar(page))).toBeLessThan(await top(controls));
	expect(await top(controls)).toBeLessThan(await top(box(page)));

	// Replay and Skip act on the same reply: they share one pill.
	const playback = controls.getByRole('group', { name: 'Playback' });
	await expect(playback.getByRole('button')).toHaveCount(2);
	await expect(playback.getByRole('button', { name: 'Replay' })).toBeVisible();
	await expect(playback.getByRole('button', { name: 'Skip' })).toBeVisible();

	// Icons are drawn, not typed: speaker, replay, skip and the mic on Talk.
	await expect(controls.locator('[data-icon]')).toHaveCount(3);
	await expect(page.locator('[data-primary="talk"] [data-icon="mic"]')).toBeVisible();
	expect(await page.locator('[data-dock]').innerText()).not.toMatch(/[⌨🔊🔇🎙⏭↻]/u);
	// Manual has no mute control; Auto has one.
	await expect(controls.getByRole('button', { name: 'Microphone' })).toHaveCount(0);
	await shot(page, 'controls-thread');
});
