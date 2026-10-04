import { expect, test, type Page } from '@playwright/test';
import {
	drag,
	dragStart,
	drawer,
	expectDrawerClosed,
	expectDrawerOpen,
	fresh,
	threadPath,
	TOKEN,
	TOKEN_HEADER,
	touchDrag
} from './helpers';

/** The manager's thread: its chat rows. */
const said = (page: Page) => page.locator('[data-view="chat"]');
const sheet = (page: Page) => page.locator('[data-sheet]');
const grip = (page: Page) => sheet(page).locator('.grip');

/** Bring the board sheet to a stop with its handle: 1 open, 2 tall. */
async function openBoard(page: Page, stop: 1 | 2 = 2): Promise<void> {
	for (let at = 0; at < stop; at += 1) await grip(page).click();
	await expect(sheet(page)).toHaveAttribute('data-stop', String(stop));
	// Let the sheet settle before anything is measured or dragged.
	await expect
		.poll(async () => {
			const first = (await sheet(page).boundingBox())?.y;
			await page.waitForTimeout(80);
			return (await sheet(page).boundingBox())?.y === first;
		})
		.toBe(true);
}
const box = (page: Page) => page.getByRole('textbox', { name: 'Ask the manager' });
const offBox = (page: Page) => page.getByRole('textbox', { name: 'Off in MuxMaestro Settings' });
const homeRow = (page: Page) => drawer(page).locator('[data-home]');
const review = (page: Page) => page.locator('[data-review]');

test('the app opens on the manager home', async ({ page }) => {
	await fresh(page);
	await expect(page.locator('.chip').first()).toHaveText('2 need you');
	await expect(said(page).locator('.a')).toHaveText(
		'Two threads need you. Four are running. Nothing has failed in the last hour.'
	);
	await expect(page.locator('.sect').first()).toHaveText('Needs you · 2');
	await expect(page.locator('a.item').first()).toContainText('acme-app · checkout-fix');
	await expect(page.locator('a.item').first()).toContainText('Permission · Bash · 2m');
	await expect(page.locator('a.item').nth(1)).toContainText('Question · 6m');
	await expect(review(page)).toHaveCount(1);
	await expect(review(page)).toContainText('billing · invoices-pdf');
	await expect(review(page)).toContainText('PR open 52m, CI green, no review yet');
});

test('a message to the manager streams its reply onto the home', async ({ page }) => {
	await fresh(page);
	// With nothing typed the button is Talk, which arrives with voice.
	await expect(page.getByRole('button', { name: 'Talk', exact: true })).toBeDisabled();
	await box(page).fill('what needs me?');
	const sent = page.waitForRequest((request) => request.url().endsWith('/api/manager/text'));
	await page.getByRole('button', { name: '↑ Send' }).click();
	const request = await sent;
	expect(request.method()).toBe('POST');
	expect(request.headers()['x-muxmaestro']).toBe('1');
	expect(request.postDataJSON()).toEqual({ text: 'what needs me?' });

	await expect(box(page)).toHaveValue('');
	await expect(said(page).locator('.u')).toHaveText('what needs me?');
	await expect(said(page).locator('.a').last()).toHaveText(
		'2 threads need you: acme-app · checkout-fix, billing · proration.'
	);
	// The turn is in the chat now: a reload shows the same lines.
	await page.reload();
	await expect(said(page).locator('.u')).toHaveText('what needs me?');
	await expect(said(page).locator('.a').last()).toHaveText(
		'2 threads need you: acme-app · checkout-fix, billing · proration.'
	);
	await expect(page.getByRole('alert')).toHaveCount(0);
});

test('Enter sends too', async ({ page }) => {
	await fresh(page);
	await box(page).fill('what needs me?');
	await box(page).press('Enter');
	await expect(said(page).locator('.a').last()).toContainText('2 threads need you');
});

test('a refused turn says why and gives the text back', async ({ page }) => {
	await fresh(page);
	await page.request.post('/__fixture/manager-status?value=waiting');
	await box(page).fill('what needs me?');
	await page.getByRole('button', { name: '↑ Send' }).click();
	await expect(page.getByRole('alert')).toHaveText('Manager is waiting on a prompt');
	await expect(box(page)).toHaveValue('what needs me?');
	await expect(said(page).locator('.u')).toHaveCount(0);

	// The prompt is answered on the Mac: the same text goes through.
	await page.request.post('/__fixture/manager-status?value=idle');
	await page.getByRole('button', { name: '↑ Send' }).click();
	await expect(said(page).locator('.a').last()).toContainText('2 threads need you');
	await expect(page.getByRole('alert')).toHaveCount(0);
});

test('a turn typed on the Mac shows on the phone, and holds Send until it ends', async ({
	page
}) => {
	await fresh(page);
	await expect(said(page).locator('.a')).toHaveCount(1);
	await box(page).fill('and after that?');
	const reply = 'All four are still running. ' + 'Nothing new. '.repeat(12).trim();
	await page.request.post(
		`/__fixture/mac-turn?text=${encodeURIComponent('how are the builds?')}&reply=${encodeURIComponent(reply)}`
	);
	await expect(said(page).locator('.u')).toHaveText('how are the builds?');
	await expect(page.getByRole('button', { name: '↑ Send' })).toBeDisabled();
	await expect(said(page).locator('.a').last()).toHaveText(reply);
	await expect(page.getByRole('button', { name: '↑ Send' })).toBeEnabled();
	await expect(box(page)).toHaveValue('and after that?');
});

test('a "Needs you" card opens its thread', async ({ page }) => {
	await fresh(page);
	await openBoard(page, 1);
	await page.locator('a.item[data-thread="localhost:1"]').click();
	await expect(page).toHaveURL(/\/t\/localhost(:|%3A)1$/);
	await expect(page.locator('.tbar .title b')).toHaveText('acme-app · checkout-fix');
	await expect(page.locator('.u').first()).toHaveText(
		'fix the failing checkout test and open a PR'
	);
});

test('a review card opens its thread', async ({ page }) => {
	await fresh(page);
	await openBoard(page);
	await review(page).locator('a.open').click();
	await expect(page).toHaveURL(/\/t\/localhost(:|%3A)9$/);
	await expect(page.locator('.tbar .title b')).toHaveText('billing · invoices-pdf');
});

test('a left swipe dismisses a review item, on the Mac too', async ({ page }) => {
	await fresh(page);
	await openBoard(page);
	const card = await review(page).boundingBox();
	if (!card) throw new Error('no review card');
	const y = card.y + card.height / 2;

	// A short drag follows the finger and springs back.
	await drag(page, [300, y], [250, y]);
	await expect(review(page)).toHaveCount(1);
	await expect
		.poll(() => review(page).evaluate((el) => Math.round(el.getBoundingClientRect().left)))
		.toBe(Math.round(card.x));

	const dismissed = page.waitForRequest((request) =>
		request.url().endsWith('/api/manager/dismiss')
	);
	await drag(page, [320, y], [80, y]);
	expect((await dismissed).postDataJSON()).toEqual({ key: 'billing:invoices-pdf' });
	await expect(review(page)).toHaveCount(0);
	await expect(page.getByText('Review ·')).toHaveCount(0);
	// It did not open the thread, and it stays gone.
	await expect(page).toHaveURL(/\/$/);
	await page.reload();
	await expect(grip(page)).toContainText('2 need you · 2 updates');
	await expect(review(page)).toHaveCount(0);
});

test('the dismiss button does the same as the swipe', async ({ page }) => {
	await fresh(page);
	await openBoard(page);
	await page.getByRole('button', { name: 'Dismiss billing · invoices-pdf' }).click();
	await expect(review(page)).toHaveCount(0);
	await page.reload();
	await expect(grip(page)).toContainText('2 need you · 2 updates');
	await expect(review(page)).toHaveCount(0);
});

test('a right swipe on the home still opens the sidebar, over a review card too', async ({
	page
}) => {
	await fresh(page);
	await openBoard(page);
	const card = await review(page).boundingBox();
	if (!card) throw new Error('no review card');
	await drag(page, [60, card.y + 20], [300, card.y + 24]);
	await expectDrawerOpen(page);
	await expect(review(page)).toHaveCount(1);
});

test('Manager switch on: the text box is enabled and asks for a message', async ({ page }) => {
	await fresh(page);
	await expect(box(page)).toBeEnabled();
	await expect(box(page)).toHaveAttribute('placeholder', 'Ask the manager');
	await expect(offBox(page)).toHaveCount(0);
	await expect(page.getByRole('button', { name: 'Talk', exact: true })).toBeVisible();
});

test('Manager switch off: the text box stays, disabled, and says where the switch is', async ({
	page
}) => {
	await fresh(page);
	await expect(box(page)).toBeVisible();
	await page.request.post('/__fixture/capability?name=manager&on=0');
	await expect(offBox(page)).toBeVisible();
	await expect(offBox(page)).toBeDisabled();
	await expect(offBox(page)).toHaveAttribute('placeholder', 'Off in MuxMaestro Settings');
	await expect(box(page)).toHaveCount(0);
	// The talk button is still drawn, and nothing can be sent.
	await expect(page.getByRole('button', { name: 'Talk to the manager' })).toBeDisabled();
	await expect(page.getByRole('button', { name: 'Talk', exact: true })).toBeDisabled();
	await expect(page.getByRole('button', { name: '↑ Send' })).toHaveCount(0);
	// Nothing of the manager itself is drawn.
	await expect(said(page)).toHaveCount(0);
	await expect(review(page)).toHaveCount(0);
	await expect(page.locator('[data-update]')).toHaveCount(0);
	await expect(page.locator('[data-voicebar]')).toHaveCount(0);
	// The threads that wait are still listed: they come from the thread list.
	await expect(page.locator('.sect').first()).toHaveText('Needs you · 2');
	expect(
		await page.evaluate(
			async (headers) => (await fetch('/api/manager', { headers })).status,
			TOKEN_HEADER
		)
	).toBe(403);

	// Off at first paint too: the box is there, and no request goes to the manager.
	let asked = 0;
	page.on('request', (request) => {
		if (request.url().includes('/api/manager')) asked += 1;
	});
	await page.reload();
	await expect(offBox(page)).toBeDisabled();
	await expect(page.locator('.sect').first()).toHaveText('Needs you · 2');
	expect(asked).toBe(0);

	// Switched on again on the Mac: the box works without a reload.
	await page.request.post('/__fixture/capability?name=manager&on=1');
	await expect(box(page)).toBeEnabled();
	await expect(offBox(page)).toHaveCount(0);
});

for (const on of [true, false]) {
	test(`the sidebar's Manager row goes back to the home, Manager switch ${on ? 'on' : 'off'}`, async ({
		page
	}) => {
		await fresh(page, threadPath('localhost:1'));
		if (!on) await page.request.post('/__fixture/capability?name=manager&on=0');
		await expect(page.locator('.tbar .title b')).toHaveText('acme-app · checkout-fix');
		await page.getByRole('button', { name: 'Menu' }).click();
		await expectDrawerOpen(page);
		// Pinned at the top, above the grouping control, and not the current page.
		const row = await homeRow(page).boundingBox();
		const seg = await drawer(page).getByRole('tablist', { name: 'Group by' }).boundingBox();
		expect(row?.y ?? 999).toBeLessThan(seg?.y ?? 0);
		await expect(homeRow(page)).not.toHaveAttribute('aria-current', 'page');

		await homeRow(page).click();
		await expect(page).toHaveURL(/\/$/);
		await expectDrawerClosed(page);
		await expect(on ? box(page) : offBox(page)).toBeVisible();
		if (on) await expect(box(page)).toBeEnabled();
		else await expect(offBox(page)).toBeDisabled();

		// On the home the row is marked as the current page.
		await page.getByRole('button', { name: 'Menu' }).click();
		await expect(homeRow(page)).toHaveAttribute('aria-current', 'page');
	});
}

test('voice controls are drawn and do nothing', async ({ page }) => {
	await fresh(page);
	await expect(page.getByRole('button', { name: 'Talk', exact: true })).toBeDisabled();
	for (const button of await page.locator('[data-voicebar] button').all()) {
		await expect(button).toBeDisabled();
	}
	await expect(page.locator('[data-voicebar] button')).toHaveCount(6);
});

test('a write from another origin, without the header, or without the token is refused', async ({
	page
}) => {
	await fresh(page);
	const status = (headers: Record<string, string>): Promise<number> =>
		page.evaluate(async (headers) => {
			const response = await fetch('/api/manager/text', {
				method: 'POST',
				headers,
				body: JSON.stringify({ text: 'what needs me?' })
			});
			return response.status;
		}, headers);
	// Paired, but not the app's own write: no custom header.
	expect(await status({ 'content-type': 'application/json', ...TOKEN_HEADER })).toBe(403);
	const foreign = await page.request.post('/api/manager/text', {
		headers: { 'x-muxmaestro': '1', origin: 'https://evil.example.com', ...TOKEN_HEADER },
		data: { text: 'what needs me?' }
	});
	expect(foreign.status()).toBe(403);
	// The app's own write, from a phone that is not paired.
	expect(await status({ 'content-type': 'application/json', 'x-muxmaestro': '1' })).toBe(401);
	await expect(said(page).locator('.u')).toHaveCount(0);
});

test('the app sends the pairing token with a manager turn', async ({ page }) => {
	await fresh(page);
	await box(page).fill('what needs me?');
	const sent = page.waitForRequest((request) => request.url().endsWith('/api/manager/text'));
	await box(page).press('Enter');
	expect((await sent).headers()['x-muxmaestro-token']).toBe(TOKEN);
	await expect(said(page).locator('.a').last()).toContainText('2 threads need you');
});

test('the home fits a phone: no sideways scroll, the box above the home indicator', async ({
	page
}) => {
	await fresh(page);
	await expect(box(page)).toBeVisible();
	expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);
	const input = await box(page).boundingBox();
	expect(input?.height).toBeGreaterThanOrEqual(44);
	expect((input?.y ?? 0) + (input?.height ?? 0)).toBeLessThanOrEqual(844);
});

test('the manager status is drawn while a message cannot go to it', async ({ page }) => {
	await fresh(page);
	await page.request.post('/__fixture/manager-status?value=waiting');
	await page.reload();
	const status = page.locator('[data-status]');
	await expect(status).toHaveText('Manager is waiting on a prompt');
	await expect(status).toHaveAttribute('data-status', 'waiting');

	await page.request.post('/__fixture/manager-status?value=busy');
	await page.reload();
	await expect(status).toHaveText('Manager is busy');
	await box(page).fill('what needs me?');
	await box(page).press('Enter');
	await expect(page.getByRole('alert')).toHaveText('Manager is busy');
	await expect(box(page)).toHaveValue('what needs me?');

	// Running, but its pane's state is not known: not idle.
	await page.request.post('/__fixture/manager-status?value=unknown');
	await page.reload();
	await expect(status).toHaveText('Manager is not ready');
	await box(page).fill('what needs me?');
	await box(page).press('Enter');
	await expect(page.getByRole('alert')).toHaveText('Manager is not ready');

	await page.request.post('/__fixture/manager-status?value=idle');
	await page.reload();
	await expect(box(page)).toBeVisible();
	await expect(status).toHaveCount(0);
});

test('the updates are listed, and one with a thread opens it', async ({ page }) => {
	await fresh(page);
	const updates = page.locator('[data-update]');
	await expect(updates).toHaveCount(2);
	await expect(updates.first()).toContainText('docs-site · search');
	await expect(updates.first()).toContainText('Search box wired to the new index');
	await expect(updates.nth(1)).toContainText('Nightly build is green');
	await openBoard(page);
	await updates.first().click();
	await expect(page).toHaveURL(/\/t\/localhost(:|%3A)3$/);
});

test('Enter does not send a second turn while one runs', async ({ page }) => {
	await fresh(page);
	let turns = 0;
	page.on('request', (request) => {
		if (request.url().endsWith('/api/manager/text')) turns += 1;
	});
	const reply = 'Still checking. '.repeat(20).trim();
	await page.request.post(
		`/__fixture/mac-turn?text=${encodeURIComponent('how are the builds?')}&reply=${encodeURIComponent(reply)}`
	);
	await expect(said(page).locator('.u')).toHaveText('how are the builds?');
	await box(page).fill('and after that?');
	await box(page).press('Enter');
	await box(page).press('Enter');
	await expect(said(page).locator('.a').last()).toHaveText(reply);
	expect(turns).toBe(0);
	await expect(box(page)).toHaveValue('and after that?');

	// The turn is over: now Enter sends.
	await expect(page.getByRole('button', { name: '↑ Send' })).toBeEnabled();
	await box(page).press('Enter');
	await expect(said(page).locator('.u').last()).toHaveText('and after that?');
	expect(turns).toBe(1);
});

test('a message over the size limit says so and is given back', async ({ page }) => {
	await fresh(page);
	const long = 'a'.repeat(8193);
	await box(page).fill(long);
	await box(page).press('Enter');
	await expect(page.getByRole('alert')).toHaveText('The message is too long');
	await expect(box(page)).toHaveValue(long);
});

test('dismissing a review item that does not exist is a 404', async ({ page }) => {
	await fresh(page);
	const gone = await page.request.post('/api/manager/dismiss', {
		headers: { 'x-muxmaestro': '1', origin: new URL(page.url()).origin, ...TOKEN_HEADER },
		data: { key: 'no-such-item' }
	});
	expect(gone.status()).toBe(404);
	await expect(review(page)).toHaveCount(1);
});

test('the manager page is its thread: left-aligned rows and the Chat/Terminal toggle', async ({
	page
}) => {
	await fresh(page);
	const tab = page.locator('[data-tab="main"]');
	await expect(tab).toHaveText(/Chat\s*⇄/);
	const reply = said(page).locator('.a').first();
	await expect(reply).toHaveText(
		'Two threads need you. Four are running. Nothing has failed in the last hour.'
	);
	await expect(reply).toHaveCSS('text-align', 'start');
	const edge = (await said(page).boundingBox())?.x ?? 0;
	expect(((await reply.boundingBox())?.x ?? 99) - edge).toBeLessThan(20);
	// The status chips stay on top, and no thread header is drawn for the manager.
	await expect(page.locator('.chip').first()).toHaveText('2 need you');
	await expect(page.locator('.tbar.thread')).toHaveCount(0);

	// The same toggle as a session page: the manager pane's terminal.
	await tab.click();
	await expect(tab).toHaveText(/Terminal\s*⇄/);
	const screen = page.locator('[data-view="terminal"]');
	await expect(screen).toContainText('Two threads need you.');
	await expect(screen).toContainText('? for shortcuts');
	await expect(said(page)).toHaveCount(0);
	await tab.click();
	await expect(tab).toHaveText(/Chat\s*⇄/);
	await expect(reply).toBeVisible();
});

test('the manager thread shows tool lines and user turns like any chat', async ({ page }) => {
	await fresh(page);
	await box(page).fill('what needs me?');
	await box(page).press('Enter');
	await expect(said(page).locator('.a').last()).toContainText('2 threads need you');
	const turn = said(page).locator('.u');
	await expect(turn).toHaveText('what needs me?');
	// A user turn sits on the right, as in every chat.
	const row = await turn.boundingBox();
	const view = await said(page).boundingBox();
	expect((row?.x ?? 0) + (row?.width ?? 0)).toBeGreaterThan((view?.width ?? 0) - 30);
	await expect(page.locator('[data-pending]')).toHaveCount(0);
});

test("thinking: the pane's own spinner line is shown while a turn runs", async ({ page }) => {
	await fresh(page);
	const reply = 'All four are still running. '.repeat(8).trim();
	await page.request.post(
		`/__fixture/mac-turn?text=${encodeURIComponent('how are the builds?')}&reply=${encodeURIComponent(reply)}&spinner=${encodeURIComponent('Incubating… 4m 48s')}`
	);
	const thinking = page.locator('[data-thinking]');
	await expect(thinking).toHaveText('Incubating… 4m 48s');
	// The dots stay beside the line.
	await expect(thinking.locator('.dots i')).toHaveCount(3);
	// The prompt is drawn once: first as sent, then from the chat.
	await expect(said(page).locator('.u')).toHaveCount(1);
	await expect(said(page).locator('.a').last()).toHaveText(reply);
	await expect(thinking).toHaveCount(0);
});

test('thinking: with no spinner line the phrases rotate, with a timer', async ({ page }) => {
	await fresh(page);
	const reply = 'Still checking. '.repeat(160).trim();
	await page.request.post(
		`/__fixture/mac-turn?text=${encodeURIComponent('how are the builds?')}&reply=${encodeURIComponent(reply)}`
	);
	const thinking = page.locator('[data-thinking-text]');
	await expect(thinking).toHaveText(/^Thinking… [0-3]s$/);
	const first = await thinking.textContent();
	// The timer moves, and after a few seconds the phrase changes.
	await expect(thinking).not.toHaveText(first ?? '');
	await expect(thinking).toHaveText(/^Reading the threads… [4-7]s$/, { timeout: 8000 });
});

test('the board is a bottom sheet: a peek, then open, then 70% tall', async ({ page }) => {
	await fresh(page);
	const height = async (): Promise<number> => {
		const stage = await page.locator('.stage').boundingBox();
		const top = (await sheet(page).boundingBox())?.y ?? 0;
		return Math.round((stage?.y ?? 0) + (stage?.height ?? 0) - top);
	};
	const input = await box(page).boundingBox();

	// Rest: a handle and a one-line summary; the thread has the screen.
	await expect(sheet(page)).toHaveAttribute('data-stop', '0');
	await expect(grip(page)).toContainText('2 need you · 1 review · 2 updates');
	expect(await height()).toBe(46);
	await expect(sheet(page).locator('[data-sheet-list]')).toHaveAttribute('inert', '');

	// The handle steps up, and from the top goes back to rest.
	await openBoard(page, 1);
	const open = await height();
	expect(open).toBeGreaterThan(200);
	expect(open).toBeLessThan(400);
	await grip(page).click();
	await expect(sheet(page)).toHaveAttribute('data-stop', '2');
	await expect.poll(height).toBe(Math.round(844 * 0.7));
	// The text box and the voice bar have not moved.
	expect(await box(page).boundingBox()).toEqual(input);
	await expect(page.locator('[data-voicebar]')).toBeVisible();
	// The counters stay where they are.
	await expect(page.locator('.chip').first()).toBeVisible();
	await grip(page).click();
	await expect(sheet(page)).toHaveAttribute('data-stop', '0');
	await expect.poll(height).toBe(46);
});

test('the sheet follows a swipe: up twice to tall, down twice to rest', async ({ page }) => {
	await fresh(page);
	const top = async (): Promise<number> => (await sheet(page).boundingBox())?.y ?? 0;
	const settled = async (stop: string): Promise<void> => {
		await expect(sheet(page)).toHaveAttribute('data-stop', stop);
		await page.waitForTimeout(450);
	};
	const rest = await top();

	// It follows the finger before it settles.
	await dragStart(page, [195, rest + 20], [195, rest - 100]);
	expect(await top()).toBeLessThan(rest - 90);
	expect(await top()).toBeGreaterThan(rest - 125);
	await page.mouse.up();
	await settled('1');

	// A second swipe up, inside the sheet, pulls it to the tall stop.
	const open = await top();
	await drag(page, [195, open + 120], [195, open - 80]);
	await settled('2');

	// Down steps back one stop at a time; the handle always moves the sheet.
	const tall = await top();
	await drag(page, [195, tall + 20], [195, tall + 140]);
	await settled('1');
	await drag(page, [195, (await top()) + 20], [195, (await top()) + 140]);
	await settled('0');
	expect(await top()).toBe(rest);

	// A small move springs back.
	await drag(page, [195, rest + 20], [195, rest + 4]);
	await settled('0');
	expect(await top()).toBe(rest);
});

test("the sheet's list scrolls only at the tall stop, and scrolls back before the sheet steps down", async ({
	page
}) => {
	await fresh(page);
	// Enough cards that the list is longer than the tall sheet.
	for (const id of ['localhost:3', 'localhost:4', 'devbox:5', 'localhost:6', 'localhost:7']) {
		await page.request.post(`/__fixture/wait?id=${id}`);
	}
	await expect(grip(page)).toContainText('7 need you');
	const list = sheet(page).locator('[data-sheet-list]');
	const scrolled = (): Promise<number> => list.evaluate((el) => el.scrollTop);

	// Open: a swipe up on the list moves the sheet, not the list.
	await openBoard(page, 1);
	const open = (await sheet(page).boundingBox())?.y ?? 0;
	await drag(page, [195, open + 150], [195, open + 40]);
	await expect(sheet(page)).toHaveAttribute('data-stop', '2');
	expect(await scrolled()).toBe(0);
	await page.waitForTimeout(450);

	// Tall: a swipe up scrolls the list.
	const tall = (await sheet(page).boundingBox())?.y ?? 0;
	await drag(page, [195, tall + 400], [195, tall + 200]);
	await expect(sheet(page)).toHaveAttribute('data-stop', '2');
	expect(await scrolled()).toBeGreaterThan(150);

	// A swipe down scrolls it back first; the sheet stays tall.
	await drag(page, [195, tall + 200], [195, tall + 520]);
	await expect.poll(scrolled).toBe(0);
	await expect(sheet(page)).toHaveAttribute('data-stop', '2');
	// From the top of the list, the next swipe down steps the sheet back.
	await drag(page, [195, tall + 200], [195, tall + 320]);
	await expect(sheet(page)).toHaveAttribute('data-stop', '1');
});

test('a swipe up on the thread at its end brings the board up', async ({ page }) => {
	await fresh(page);
	await expect(said(page).locator('.a').first()).toBeVisible();
	await expect(sheet(page)).toHaveAttribute('data-stop', '0');
	// A swipe down there does nothing to the board.
	await touchDrag(page, [195, 300], [195, 420]);
	await expect(sheet(page)).toHaveAttribute('data-stop', '0');
	await touchDrag(page, [195, 420], [195, 300]);
	await expect(sheet(page)).toHaveAttribute('data-stop', '1');
});

test('the sheet does not fight the sidebar swipe or the toggle', async ({ page }) => {
	await fresh(page);
	await openBoard(page, 1);
	const top = (await sheet(page).boundingBox())?.y ?? 0;
	// A sideways drag on the sheet opens the sidebar and leaves the sheet alone.
	await drag(page, [60, top + 30], [300, top + 36]);
	await expectDrawerOpen(page);
	await expect(sheet(page)).toHaveAttribute('data-stop', '1');
	await drag(page, [300, 400], [60, 404]);
	await expectDrawerClosed(page);
	// The toggle above it still switches.
	await page.locator('[data-tab="main"]').click();
	await expect(page.locator('[data-tab="main"]')).toHaveText(/Terminal\s*⇄/);
	await expect(sheet(page)).toHaveAttribute('data-stop', '1');
});

test('layout: the page ends at the bottom of the screen, with no empty band', async ({ page }) => {
	await fresh(page);
	await expect(box(page)).toBeVisible();
	const form = await page.locator('form.compose').boundingBox();
	// The text box row is the last thing, and it ends where the screen ends.
	expect(Math.round((form?.y ?? 0) + (form?.height ?? 0))).toBe(844);
	expect(await page.evaluate(() => document.documentElement.scrollHeight)).toBe(844);
	expect(await page.evaluate(() => getComputedStyle(document.body).height)).toBe('844px');
	// The same with the Manager switch off.
	await page.request.post('/__fixture/capability?name=manager&on=0');
	await expect(offBox(page)).toBeVisible();
	const off = await page.locator('form.compose').boundingBox();
	expect(Math.round((off?.y ?? 0) + (off?.height ?? 0))).toBe(844);
});

test('layout: a long reply is not cut off under the counters', async ({ page }) => {
	await fresh(page);
	const reply = ('First line of a long reply. ' + 'More detail follows here. '.repeat(120)).trim();
	await page.request.post(
		`/__fixture/mac-turn?text=${encodeURIComponent('summarise everything')}&reply=${encodeURIComponent(reply)}&ms=1`
	);
	const last = said(page).locator('.a').last();
	await expect(last).toHaveText(reply);
	// The reply is taller than the screen; it scrolls, under the toolbar and tabs.
	const tabs = await page.locator('.tabs').boundingBox();
	const view = await said(page).boundingBox();
	expect(view?.y ?? 0).toBeGreaterThanOrEqual((tabs?.y ?? 0) + (tabs?.height ?? 0) - 1);
	expect((await last.boundingBox())?.height ?? 0).toBeGreaterThan(view?.height ?? 0);
	// Its first line can be scrolled into view, below the tabs.
	await said(page).evaluate((el) => (el.scrollTop = 0));
	await expect(said(page).locator('.a').first()).toBeInViewport();
	// Scroll the chat, and only the chat, until the long reply starts at its top.
	await said(page).evaluate((el) => {
		const reply = [...el.querySelectorAll('.a')].at(-1);
		if (reply) el.scrollTop += reply.getBoundingClientRect().top - el.getBoundingClientRect().top;
	});
	const start = (await last.boundingBox())?.y ?? 0;
	expect(Math.abs(start - (view?.y ?? 0))).toBeLessThan(2);
	await expect(page.locator('.chip').first()).toBeInViewport();
	// And the end of it is not hidden under the board's peek.
	await said(page).evaluate((el) => (el.scrollTop = el.scrollHeight));
	const end = await last.boundingBox();
	const peek = (await sheet(page).boundingBox())?.y ?? 0;
	expect((end?.y ?? 0) + (end?.height ?? 0)).toBeLessThanOrEqual(peek + 1);
});

test('the waiting state is shown once, with a way to the terminal', async ({ page }) => {
	await fresh(page);
	await page.request.post('/__fixture/manager-status?value=waiting');
	await page.reload();
	await expect(page.locator('[data-status]')).toHaveText('Manager is waiting on a prompt');
	await expect(page.getByText('Manager is waiting on a prompt')).toHaveCount(1);
	// A refused send says it once too, not beside the status.
	await box(page).fill('what needs me?');
	await box(page).press('Enter');
	await expect(page.getByRole('alert')).toHaveText('Manager is waiting on a prompt');
	await expect(page.getByText('Manager is waiting on a prompt')).toHaveCount(1);

	// The prompt is in the pane: one tap shows the terminal.
	await page.getByRole('button', { name: 'Terminal', exact: true }).click();
	await expect(page.locator('[data-tab="main"]')).toHaveText(/Terminal\s*⇄/);
	await expect(page.locator('[data-view="terminal"]')).toContainText('Do you want to proceed?');
});
