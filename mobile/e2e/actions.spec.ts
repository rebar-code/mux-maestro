import { expect, test, type Locator, type Page } from '@playwright/test';
import { drawer, expectDrawerOpen, fresh, threadPath, TOKEN_HEADER, touchDrag } from './helpers';

const sheet = (page: Page): Locator => page.getByRole('dialog');
const row = (page: Page, id: string): Locator => drawer(page).locator(`[data-thread="${id}"]`);
const session = (page: Page, key: string): Locator =>
	drawer(page).locator(`[data-session="${key}"]`);
const hostCard = (page: Page, name: string): Locator =>
	drawer(page).locator(`[data-host="${name}"]`);

/** Screenshots are taken only when SHOTS names a directory outside the repo. */
async function shot(page: Page, name: string): Promise<void> {
	const dir = process.env.SHOTS;
	if (!dir) return;
	// Let the sheet's slide-in end.
	await page.waitForTimeout(300);
	await page.screenshot({ path: `${dir}/${name}.png` });
}

async function allow(page: Page, ...names: string[]): Promise<void> {
	for (const name of names) await page.request.post(`/__fixture/capability?name=${name}&on=1`);
}

async function actions(page: Page): Promise<Record<string, unknown>[]> {
	const sent = await (await page.request.post('/__fixture/replies')).json();
	return sent.actions as Record<string, unknown>[];
}

/** Press on the middle of `target` and hold, as a finger would. */
async function longPress(page: Page, target: Locator, hold = 650): Promise<void> {
	await target.scrollIntoViewIfNeeded();
	const box = await target.boundingBox();
	if (!box) throw new Error('nothing to press');
	await page.mouse.move(box.x + box.width / 3, box.y + box.height / 2);
	await page.mouse.down();
	await page.waitForTimeout(hold);
	await page.mouse.up();
}

async function openDrawer(page: Page): Promise<void> {
	await page.getByRole('button', { name: 'Menu' }).click();
	await expectDrawerOpen(page);
}

test.beforeEach(async ({ page }) => {
	await fresh(page);
	await allow(page, 'sessionActions', 'kill');
	await openDrawer(page);
});

test('a long press opens the row menu and does not tap the row', async ({ page }) => {
	await longPress(page, row(page, 'localhost:3'));
	await expect(sheet(page)).toBeVisible();
	await expect(sheet(page).locator('.title')).toHaveText('docs-site · search');
	await expect(sheet(page).getByRole('button')).toHaveText([
		'New Window…',
		'Rename Window…',
		'Archive Window',
		'Zoom Pane',
		'Kill Window'
	]);
	// The press did not open the thread, and the sidebar stayed.
	await expect(page).toHaveURL(/\/$/);
	await expectDrawerOpen(page);
	// It selected no text, and the browser's own menu is held back.
	expect(await page.evaluate(() => String(getSelection()))).toBe('');
	const held = await row(page, 'localhost:3').evaluate(
		(el) => !el.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true }))
	);
	expect(held).toBe(true);
	expect(await row(page, 'localhost:3').evaluate((el) => getComputedStyle(el).userSelect)).toBe(
		'none'
	);
	await shot(page, 'menu-window');

	// Every item is a full touch target.
	for (const item of await sheet(page).getByRole('button').all()) {
		expect((await item.boundingBox())?.height ?? 0).toBeGreaterThanOrEqual(44);
	}

	// The scrim closes the sheet; a tap still opens the thread.
	await page.getByRole('button', { name: 'Close menu' }).click({ position: { x: 195, y: 80 } });
	await expect(sheet(page)).toBeHidden();
	await row(page, 'localhost:3').click();
	await expect(page).toHaveURL(/\/t\/localhost(:|%3A)3$/);
});

test('a press that moves is a scroll, not a long press', async ({ page }) => {
	const box = await row(page, 'localhost:3').boundingBox();
	if (!box) throw new Error('no row');
	await page.mouse.move(box.x + 60, box.y + 20);
	await page.mouse.down();
	await page.mouse.move(box.x + 60, box.y + 50, { steps: 4 });
	await page.waitForTimeout(650);
	await page.mouse.up();
	await expect(sheet(page)).toBeHidden();
});

test('session and host rows have their own menus', async ({ page }) => {
	await longPress(page, session(page, 'localhost/acme-app'));
	await expect(sheet(page).locator('.title')).toHaveText('acme-app');
	await expect(sheet(page).getByRole('button')).toHaveText([
		'New Window…',
		'Rename…',
		'Kill Session'
	]);
	await shot(page, 'menu-session');
	await page.keyboard.press('Escape');
	await expect(sheet(page)).toBeHidden();

	await longPress(page, hostCard(page, 'devbox'));
	await expect(sheet(page).locator('.title')).toHaveText('devbox');
	await expect(sheet(page).getByRole('button')).toHaveText(['New Session…']);
	await shot(page, 'menu-host');
});

test('a window with two threads can lose one pane', async ({ page }) => {
	await page.request.post('/__fixture/panes?id=localhost:3&value=2');
	await longPress(page, row(page, 'localhost:3'));
	await expect(sheet(page).getByRole('button', { name: 'Kill Pane' })).toBeVisible();
});

test('with the switches off, a long press does nothing and Kill is not offered', async ({
	page
}) => {
	await page.request.post('/__fixture/capability?name=kill&on=0');
	await longPress(page, row(page, 'localhost:3'));
	await expect(sheet(page).getByRole('button', { name: 'New Window…' })).toBeVisible();
	await expect(sheet(page).getByRole('button', { name: /Kill/ })).toHaveCount(0);
	await page.keyboard.press('Escape');

	await page.request.post('/__fixture/capability?name=sessionActions&on=0');
	await expect(page.getByRole('button', { name: 'New window in acme-app' })).toBeDisabled();
	await longPress(page, row(page, 'localhost:3'));
	await expect(sheet(page)).toBeHidden();
	// The Mac refuses too, whatever the phone draws.
	const refused = await page.request.post('/api/tmux/new-window', {
		headers: { ...TOKEN_HEADER, 'x-muxmaestro': '1', origin: new URL(page.url()).origin },
		data: { host: 'localhost', session: 'acme-app' }
	});
	expect(refused.status()).toBe(403);
});

const start = (page: Page, kind: string): Locator => sheet(page).locator(`[data-start="${kind}"]`);
const view = (page: Page): Locator => page.locator('[data-mode]');

test('the + on a session row asks what to start, and Claude opens in chat', async ({ page }) => {
	await allow(page, 'replies');
	// The row also holds the button that folds the session.
	await session(page, 'localhost/docs-site')
		.getByRole('button', { name: 'New window in docs-site' })
		.click();
	await expect(sheet(page)).toHaveAttribute('data-action-sheet', 'start');
	await expect(sheet(page).getByRole('button')).toHaveText(['Claude', 'Codex', 'Terminal']);
	// Nothing is made until one is picked.
	expect(await actions(page)).toEqual([]);
	await shot(page, 'new-window-chooser');

	await start(page, 'claude').click();
	await expect(page).toHaveURL(/\/t\/localhost(:|%3A)\d+$/);
	await expect(page.locator('.tbar .title b')).toHaveText('docs-site · zsh');
	await expect(sheet(page)).toBeHidden();
	// The session is named by one of its threads.
	expect(await actions(page)).toEqual([
		{ action: 'new-window', thread: 'localhost:3', agent: 'claude' }
	]);
	// Chat at once, before the agent has a first message.
	await expect(view(page)).toHaveAttribute('data-mode', 'chat');
	await expect(page.getByText('Closed', { exact: true })).toHaveCount(0);
	const box = page.getByRole('textbox', { name: 'Reply' });
	await expect(box).toBeEditable();
	await box.fill('run the tests');
	await page.locator('form.compose').evaluate((form: HTMLFormElement) => form.requestSubmit());
	await expect(page.locator('section').getByText('run the tests')).toBeVisible();
	await shot(page, 'new-window');
});

test('Codex starts in chat and Terminal opens a shell', async ({ page }) => {
	const add = session(page, 'localhost/docs-site').getByRole('button', {
		name: 'New window in docs-site'
	});
	await add.click();
	await start(page, 'codex').click();
	await expect(page).toHaveURL(/\/t\/localhost(:|%3A)\d+$/);
	await expect(view(page)).toHaveAttribute('data-mode', 'chat');

	await openDrawer(page);
	await add.click();
	await start(page, 'terminal').click();
	await expect(sheet(page)).toBeHidden();
	await expect(view(page)).toHaveAttribute('data-mode', 'terminal');
	// A terminal is asked for with no `agent` at all.
	expect(await actions(page)).toEqual([
		{ action: 'new-window', thread: 'localhost:3', agent: 'codex' },
		{ action: 'new-window', thread: expect.stringMatching(/^localhost:\d+$/) }
	]);
});

test('New Window in a row menu asks too, and a remote Claude opens as a chat', async ({ page }) => {
	await longPress(page, row(page, 'devbox:2'));
	await sheet(page).getByRole('button', { name: 'New Window…' }).click();
	await expect(sheet(page)).toHaveAttribute('data-action-sheet', 'start');
	await start(page, 'claude').click();
	await expect(page).toHaveURL(/\/t\/devbox(:|%3A)\d+$/);
	expect(await actions(page)).toEqual([
		{ action: 'new-window', thread: 'devbox:2', agent: 'claude' }
	]);
	await expect(view(page)).toHaveAttribute('data-mode', 'chat');
});

test('a remote Codex opens as a terminal: it has no chat', async ({ page }) => {
	await longPress(page, row(page, 'devbox:2'));
	await sheet(page).getByRole('button', { name: 'New Window…' }).click();
	await start(page, 'codex').click();
	await expect(page).toHaveURL(/\/t\/devbox(:|%3A)\d+$/);
	await expect(view(page)).toHaveAttribute('data-mode', 'terminal');
});

test('the Mac refuses an agent it does not know', async ({ page }) => {
	const refused = await page.request.post('/api/tmux/new-window', {
		headers: { ...TOKEN_HEADER, 'x-muxmaestro': '1', origin: new URL(page.url()).origin },
		data: { thread: 'localhost:3', agent: 'vim' }
	});
	expect(refused.status()).toBe(400);
	expect(await refused.json()).toEqual({ error: 'bad_agent' });
});

test('rename a window, and a name the Mac would refuse cannot be sent', async ({ page }) => {
	await longPress(page, row(page, 'localhost:3'));
	await sheet(page).getByRole('button', { name: 'Rename Window…' }).click();
	const name = sheet(page).getByRole('textbox', { name: 'Name' });
	await expect(name).toHaveValue('search');
	await expect(name).toBeFocused();
	const rename = sheet(page).getByRole('button', { name: 'Rename' });

	for (const bad of ['a:b', 'a.b', '-t', '$(id)', '   ']) {
		await name.fill(bad);
		await expect(rename).toBeDisabled();
	}
	expect(await actions(page)).toEqual([]);

	await name.fill('search box');
	await shot(page, 'rename');
	await rename.click();
	await expect(sheet(page)).toBeHidden();
	await expect(row(page, 'localhost:3').locator('.name')).toHaveText('search box');
	expect(await actions(page)).toEqual([
		{ action: 'rename-window', thread: 'localhost:3', name: 'search box' }
	]);
});

test('rename a session, and a name that is taken says so', async ({ page }) => {
	await longPress(page, session(page, 'localhost/docs-site'));
	await sheet(page).getByRole('button', { name: 'Rename…' }).click();
	const name = sheet(page).getByRole('textbox', { name: 'Name' });
	await name.fill('acme-app');
	await name.press('Enter');
	await expect(sheet(page).getByRole('alert')).toHaveText('Name is taken');
	await name.fill('docs');
	await name.press('Enter');
	await expect(sheet(page)).toBeHidden();
	await expect(session(page, 'localhost/docs')).toBeVisible();
	await expect(session(page, 'localhost/docs-site')).toHaveCount(0);
});

test('kill asks first, and only Kill sends it', async ({ page }) => {
	await longPress(page, row(page, 'localhost:3'));
	await sheet(page).getByRole('button', { name: 'Kill Window' }).click();
	await expect(sheet(page).locator('.title')).toHaveText('Kill “docs-site · search”?');
	await expect(sheet(page).locator('.warn')).toHaveText(
		'This closes the window and stops what runs in it.'
	);
	await shot(page, 'kill-confirm');
	// Nothing was sent yet, and Cancel sends nothing.
	expect(await actions(page)).toEqual([]);
	await sheet(page).getByRole('button', { name: 'Cancel' }).click();
	await expect(sheet(page)).toBeHidden();
	await expect(row(page, 'localhost:3')).toBeVisible();
	expect(await actions(page)).toEqual([]);

	await longPress(page, row(page, 'localhost:3'));
	await sheet(page).getByRole('button', { name: 'Kill Window' }).click();
	await sheet(page).getByRole('button', { name: 'Kill', exact: true }).click();
	await expect(sheet(page)).toBeHidden();
	await expect(row(page, 'localhost:3')).toHaveCount(0);
	expect(await actions(page)).toEqual([
		{ action: 'kill-window', thread: 'localhost:3', confirm: true }
	]);
});

test('the Mac refuses a kill without the confirm field', async ({ page }) => {
	const write = { ...TOKEN_HEADER, 'x-muxmaestro': '1', origin: new URL(page.url()).origin };
	const refused = await page.request.post('/api/tmux/kill-window', {
		headers: write,
		data: { thread: 'localhost:3' }
	});
	expect(refused.status()).toBe(400);
	expect(await refused.json()).toEqual({ error: 'confirm_required' });
	const unknown = await page.request.post('/api/tmux/kill-server', { headers: write, data: {} });
	expect(unknown.status()).toBe(400);
	await expect(row(page, 'localhost:3')).toBeVisible();
});

test('killing the open thread leaves it', async ({ page }) => {
	await row(page, 'localhost:3').click();
	await expect(page).toHaveURL(/\/t\/localhost(:|%3A)3$/);
	await openDrawer(page);
	await longPress(page, session(page, 'localhost/docs-site'));
	await sheet(page).getByRole('button', { name: 'Kill Session' }).click();
	await expect(sheet(page).locator('.warn')).toContainText('every window in the session');
	await sheet(page).getByRole('button', { name: 'Kill', exact: true }).click();
	await expect(page).toHaveURL(/\/$/);
	await expect(session(page, 'localhost/docs-site')).toHaveCount(0);
	const sent = await actions(page);
	expect(sent).toHaveLength(1);
	expect(sent[0]).toMatchObject({ action: 'kill-session', confirm: true });
	expect(String(sent[0].thread)).toMatch(/^localhost:\d+$/);
	expect(sent[0]).not.toHaveProperty('session');

	// The Mac takes no session name for a kill.
	const byName = await page.request.post('/api/tmux/kill-session', {
		headers: { ...TOKEN_HEADER, 'x-muxmaestro': '1', origin: new URL(page.url()).origin },
		data: { host: 'localhost', session: 'acme-app', confirm: true }
	});
	expect(byName.status()).toBe(400);
});

test('the + on a host card starts a session in a directory the Mac offers', async ({ page }) => {
	await page.getByRole('button', { name: 'New session on devbox' }).scrollIntoViewIfNeeded();
	await page.getByRole('button', { name: 'New session on devbox' }).click();
	await expect(sheet(page).locator('.title')).toHaveText('New session on devbox');
	await expect(sheet(page).locator('[data-dir]')).toHaveText([
		'~/code/billing',
		'~/code/docs-site',
		'~/code/infra',
		'~/code/reports'
	]);
	await shot(page, 'new-session');
	await sheet(page).locator('[data-dir="/home/me/code/infra"]').click();
	// Nothing is made until what runs in it is picked.
	await expect(sheet(page)).toHaveAttribute('data-action-sheet', 'agent');
	await expect(sheet(page).locator('.title')).toHaveText('New session in ~/code/infra');
	expect(await actions(page)).toEqual([]);
	await start(page, 'terminal').click();
	await expect(sheet(page)).toBeHidden();
	await expect(session(page, 'devbox/infra-2')).toBeVisible();
	expect(await actions(page)).toEqual([
		{ action: 'new-session', host: 'devbox', dir: '/home/me/code/infra' }
	]);
});

test('a new session browses into a folder and starts Claude with a first prompt', async ({
	page
}) => {
	await allow(page, 'replies');
	await page.getByRole('button', { name: 'New session on localhost' }).scrollIntoViewIfNeeded();
	await page.getByRole('button', { name: 'New session on localhost' }).click();
	const dirs = sheet(page).locator('[data-dir]');
	const where = sheet(page).locator('[data-folder]');
	const use = sheet(page).getByRole('button', { name: 'Use this folder' });
	// Where the threads work is a place to start, not a folder to use.
	await expect(use).toHaveCount(0);
	await sheet(page).getByRole('button', { name: 'Browse…' }).click();
	await expect(where).toHaveText('~');
	await expect(dirs).toHaveText(['code', 'notes']);
	await dirs.filter({ hasText: 'code' }).click();
	await expect(where).toHaveText('~/code');
	await expect(dirs).toHaveText(['acme-app', 'billing', 'docs-site', 'infra', 'reports']);
	await shot(page, 'new-session-browse');
	await dirs.filter({ hasText: 'billing' }).click();
	// A folder with nothing in it can still be used, and left.
	await expect(where).toHaveText('~/code/billing');
	await expect(dirs).toHaveCount(0);
	await sheet(page).getByRole('button', { name: 'Up' }).click();
	await expect(where).toHaveText('~/code');
	await dirs.filter({ hasText: 'acme-app' }).click();
	await expect(where).toHaveText('~/code/acme-app');
	await expect(dirs).toHaveText(['api', 'web']);
	await use.click();

	await expect(sheet(page)).toHaveAttribute('data-action-sheet', 'agent');
	await expect(sheet(page).getByRole('button')).toHaveText(['Claude', 'Codex', 'Terminal']);
	await start(page, 'claude').click();
	await expect(sheet(page)).toHaveAttribute('data-action-sheet', 'prompt');
	await expect(sheet(page).locator('.title')).toHaveText('Claude in ~/code/acme-app');
	const prompt = sheet(page).getByRole('textbox', { name: 'Prompt' });
	await expect(prompt).toBeFocused();
	// A key press is not text: the Mac would refuse it, so it is not sent.
	await prompt.fill('a\u001b[2J');
	await expect(sheet(page).getByRole('button', { name: 'Start' })).toBeDisabled();
	await prompt.fill("fix the login test; it's $(broken)\nand say why");
	await shot(page, 'new-session-prompt');
	expect(await actions(page)).toEqual([]);
	await sheet(page).getByRole('button', { name: 'Start' }).click();

	await expect(page).toHaveURL(/\/t\/localhost(:|%3A)\d+$/);
	await expect(sheet(page)).toBeHidden();
	await expect(page.locator('.tbar .title b')).toHaveText('acme-app-2 · zsh');
	await expect(view(page)).toHaveAttribute('data-mode', 'chat');
	expect(await actions(page)).toEqual([
		{
			action: 'new-session',
			host: 'localhost',
			dir: '/Users/me/code/acme-app',
			agent: 'claude',
			prompt: "fix the login test; it's $(broken)\nand say why"
		}
	]);
});

test('the prompt is optional, and Up from the home goes back to where the threads work', async ({
	page
}) => {
	await page.getByRole('button', { name: 'New session on devbox' }).scrollIntoViewIfNeeded();
	await page.getByRole('button', { name: 'New session on devbox' }).click();
	await sheet(page).getByRole('button', { name: 'Browse…' }).click();
	await expect(sheet(page).locator('[data-folder]')).toHaveText('~');
	await sheet(page).getByRole('button', { name: 'Up' }).click();
	await expect(sheet(page).locator('[data-folder]')).toHaveCount(0);
	await expect(sheet(page).locator('[data-dir]')).toHaveCount(4);
	await sheet(page).getByRole('button', { name: 'Home' }).click();
	await expect(sheet(page).locator('.title')).toHaveText('New session in Home');
	await start(page, 'codex').click();
	await sheet(page).getByRole('button', { name: 'Start' }).click();
	await expect(page).toHaveURL(/\/t\/devbox(:|%3A)\d+$/);
	// No directory and no prompt are sent: the host's home, and the bare agent.
	expect(await actions(page)).toEqual([{ action: 'new-session', host: 'devbox', agent: 'codex' }]);
});

test('the Mac lists the home tree only', async ({ page }) => {
	const headers = { ...TOKEN_HEADER, 'x-muxmaestro': '1', origin: new URL(page.url()).origin };
	const list = (path: string): ReturnType<typeof page.request.get> =>
		page.request.get(`/api/hosts/devbox/dirs?path=${encodeURIComponent(path)}`, { headers });
	expect((await list('/home/me/code')).status()).toBe(200);
	for (const path of ['/etc', '/home/other', '/home/me/.ssh', '/home/me2'])
		expect((await list(path)).status(), path).toBe(400);
	const refused = await page.request.post('/api/tmux/new-session', {
		headers,
		data: { host: 'devbox', dir: '/etc', agent: 'claude' }
	});
	expect(refused.status()).toBe(400);
	expect(await actions(page)).toEqual([]);
});

test('a swipe down closes the sheet, and a short one springs back', async ({ page }) => {
	await longPress(page, row(page, 'localhost:3'));
	// Let the sheet's slide-in end, so its place is its resting place.
	await page.waitForTimeout(300);
	const box = await sheet(page).boundingBox();
	if (!box) throw new Error('no sheet');
	const x = box.x + box.width / 2;
	await touchDrag(page, [x, box.y + 20], [x, box.y + 50]);
	await expect(sheet(page)).toBeVisible();
	await expect
		.poll(async () => Math.abs(((await sheet(page).boundingBox())?.y ?? 0) - box.y))
		.toBeLessThan(1);
	// A drag that starts on an item moves the sheet and does not tap the item.
	await touchDrag(page, [x, box.y + 70], [x, box.y + 260]);
	await expect(sheet(page)).toBeHidden();
	expect(await actions(page)).toEqual([]);
	await expect(page).toHaveURL(/\/$/);
});

test.describe('find', () => {
	const LOCAL = 'localhost:1';
	const count = (page: Page): Locator => page.locator('[data-find-count]');
	const current = (page: Page): Locator => page.locator('[data-find-current]');

	test.beforeEach(async ({ page }) => {
		await allow(page, 'find');
		await page.goto(threadPath(LOCAL));
	});

	test('finds in the chat and steps through the matches', async ({ page }) => {
		await page.getByRole('button', { name: 'Find' }).click();
		const box = page.getByRole('searchbox', { name: 'Find in session' });
		await expect(box).toBeFocused();
		await expect(count(page)).toHaveText('0/0');
		await expect(page.getByRole('button', { name: 'Next match' })).toBeDisabled();

		await box.fill('tax');
		await expect(count(page)).toHaveText('1/2');
		await expect(page.locator('[data-view="chat"] mark')).toHaveCount(2);
		await expect(current(page)).toHaveText('tax');
		await expect(current(page)).toBeInViewport();
		await shot(page, 'find-chat');

		await page.getByRole('button', { name: 'Next match' }).click();
		await expect(count(page)).toHaveText('2/2');
		await page.getByRole('button', { name: 'Next match' }).click();
		await expect(count(page)).toHaveText('1/2');
		await page.getByRole('button', { name: 'Previous match' }).click();
		await expect(count(page)).toHaveText('2/2');

		// An uppercase letter makes it exact: the chat says "tax", never "Tax".
		await box.fill('Tax');
		await expect(count(page)).toHaveText('0/0');

		await page.getByRole('button', { name: 'Close find' }).click();
		await expect(box).toBeHidden();
		await expect(page.locator('mark')).toHaveCount(0);
	});

	test('finds in the terminal scrollback and scrolls to the match', async ({ page }) => {
		await page.getByRole('tab').click();
		await expect(page.locator('[data-view="terminal"]')).toBeVisible();
		await page.getByRole('button', { name: 'Find' }).click();
		await page.getByRole('searchbox', { name: 'Find in session' }).fill('tax line');

		// The newest match first: the one nearest to what the pane shows now.
		await expect(count(page)).toHaveText('6/6');
		const text = page.locator('[data-find-text]');
		await expect(text.locator('mark')).toHaveCount(6);
		await expect(current(page)).toHaveText('Tax line');
		await expect(current(page)).toBeInViewport();
		// The view shows the scrollback as the pane printed it, line for line.
		expect((await text.textContent())?.split('\n')[0]).toBe(
			'$ pnpm exec playwright test tests/checkout.spec.ts'
		);
		await shot(page, 'find-terminal');

		const scroller = page.locator('[data-view="terminal"]');
		const before = await scroller.evaluate((el) => el.scrollTop);
		for (let n = 5; n >= 1; n -= 1) {
			await page.getByRole('button', { name: 'Previous match' }).click();
			await expect(count(page)).toHaveText(`${n}/6`);
			await expect(current(page)).toBeInViewport();
		}
		expect(await scroller.evaluate((el) => el.scrollTop)).toBeLessThan(before);
		await page.getByRole('button', { name: 'Next match' }).click();
		await expect(count(page)).toHaveText('2/6');
		await page.getByRole('searchbox').press('Enter');
		await expect(count(page)).toHaveText('3/6');

		// Closing find gives the live pane back.
		await page.getByRole('button', { name: 'Close find' }).click();
		await expect(text).toHaveCount(0);
		await expect(page.locator('[data-view="terminal"] [data-lines]')).toContainText(
			'I need to run the spec'
		);
	});

	test('a find the Mac refuses as busy is asked again', async ({ page }) => {
		await page.getByRole('tab').click();
		await page.request.post('/__fixture/find-busy?value=2');
		await page.getByRole('button', { name: 'Find' }).click();
		await page.getByRole('searchbox', { name: 'Find in session' }).fill('tax line');
		await expect(count(page)).toHaveText('6/6');
	});

	test('switching the view searches the other one', async ({ page }) => {
		await page.getByRole('button', { name: 'Find' }).click();
		await page.getByRole('searchbox').fill('tax');
		await expect(count(page)).toHaveText('1/2');
		await page.getByRole('tab').click();
		await expect(count(page)).toHaveText('6/6');
		await page.getByRole('tab').click();
		await expect(count(page)).toHaveText('1/2');
	});

	test('the find controls are full touch targets', async ({ page }) => {
		await page.getByRole('button', { name: 'Find' }).click();
		for (const name of ['Previous match', 'Next match', 'Close find', 'Find']) {
			const box = await page.getByRole('button', { name, exact: true }).boundingBox();
			expect(box?.height ?? 0, name).toBeGreaterThanOrEqual(44);
			expect(box?.width ?? 0, name).toBeGreaterThanOrEqual(44);
		}
	});

	test('the Mac refuses an oversize query and a find with the switch off', async ({ page }) => {
		const path = `/api/threads/${encodeURIComponent(LOCAL)}/find`;
		const long = await page.request.get(`${path}?q=${'a'.repeat(201)}`, { headers: TOKEN_HEADER });
		expect(long.status()).toBe(400);
		await page.request.post('/__fixture/capability?name=find&on=0');
		expect((await page.request.get(`${path}?q=tax`, { headers: TOKEN_HEADER })).status()).toBe(403);
		await expect(page.getByRole('button', { name: 'Find' })).toBeDisabled();
	});
});
