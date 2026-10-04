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
/** The board: the list below the footer. */
const sheet = (page: Page) => page.locator('[data-board]');
/** The footer: the top edge of the board drawer. */
const foot = (page: Page) => page.locator('[data-foot]');
/** The grabber on the footer's top edge. */
const grip = (page: Page) => page.locator('[data-grab]');

/** Raise the footer to a stop with its grabber: 1 open, 2 tall. */
async function openBoard(page: Page, stop: 1 | 2 = 2): Promise<void> {
	for (let at = 0; at < stop; at += 1) await grip(page).click();
	await expect(sheet(page)).toHaveAttribute('data-stop', String(stop));
	// Let the sheet settle before anything is measured or dragged.
	await expect
		.poll(async () => {
			const first = (await foot(page).boundingBox())?.y;
			await page.waitForTimeout(80);
			return (await foot(page).boundingBox())?.y === first;
		})
		.toBe(true);
}
const box = (page: Page) => page.getByRole('textbox', { name: 'Ask the Maestro' });
/**
 * Submit the text box's form, as its Send button does. (On a phone, Return in
 * the box is a new line; `compose.spec.ts` covers the keys.)
 */
const submit = (page: Page): Promise<void> =>
	page.locator('form.compose').evaluate((form: HTMLFormElement) => form.requestSubmit());
const offBox = (page: Page) => page.getByRole('textbox', { name: 'Off in MuxMaestro Settings' });
const homeRow = (page: Page) => drawer(page).locator('[data-home]');
const review = (page: Page) => page.locator('[data-review]');

test('the app opens on the Maestro home', async ({ page }) => {
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

test('a message to the Maestro streams its reply onto the home', async ({ page }) => {
	await fresh(page);
	// With nothing typed there is nothing to send: the button is Talk.
	await expect(page.getByRole('button', { name: /^Send(ing)?$/ })).toHaveCount(0);
	await box(page).fill('what needs me?');
	const sent = page.waitForRequest((request) => request.url().endsWith('/api/manager/text'));
	await page.getByRole('button', { name: /^Send(ing)?$/ }).click();
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

test('the form sends too', async ({ page }) => {
	await fresh(page);
	await box(page).fill('what needs me?');
	await submit(page);
	await expect(said(page).locator('.a').last()).toContainText('2 threads need you');
});

test('a refused turn says why and gives the text back', async ({ page }) => {
	await fresh(page);
	await page.request.post('/__fixture/manager-status?value=waiting');
	await box(page).fill('what needs me?');
	await page.getByRole('button', { name: /^Send(ing)?$/ }).click();
	await expect(page.getByRole('alert')).toHaveText('Maestro is waiting on a prompt');
	await expect(box(page)).toHaveValue('what needs me?');
	await expect(said(page).locator('.u')).toHaveCount(0);

	// The prompt is answered on the Mac: the same text goes through.
	await page.request.post('/__fixture/manager-status?value=idle');
	await page.getByRole('button', { name: /^Send(ing)?$/ }).click();
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
	await expect(page.getByRole('button', { name: /^Send(ing)?$/ })).toBeDisabled();
	await expect(said(page).locator('.a').last()).toHaveText(reply);
	await expect(page.getByRole('button', { name: /^Send(ing)?$/ })).toBeEnabled();
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

test('Maestro switch on: the text box is enabled and asks for a message', async ({ page }) => {
	await fresh(page);
	await expect(box(page)).toBeEnabled();
	await expect(box(page)).toHaveAttribute('placeholder', 'Ask the Maestro');
	await expect(offBox(page)).toHaveCount(0);
	await expect(page.getByRole('button', { name: 'Talk', exact: true })).toBeVisible();
});

test('Maestro switch off: the text box stays, disabled, and says where the switch is', async ({
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
	await expect(page.getByRole('button', { name: 'Talk to the Maestro' })).toBeDisabled();
	await expect(page.getByRole('button', { name: 'Talk', exact: true })).toBeDisabled();
	await expect(page.getByRole('button', { name: /^Send(ing)?$/ })).toHaveCount(0);
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
	test(`the sidebar's Maestro row goes back to the home, Maestro switch ${on ? 'on' : 'off'}`, async ({
		page
	}) => {
		await fresh(page, threadPath('localhost:1'));
		if (!on) await page.request.post('/__fixture/capability?name=manager&on=0');
		await expect(page.locator('.tbar .title b')).toHaveText('acme-app · checkout-fix');
		await page.getByRole('button', { name: 'Menu' }).click();
		await expectDrawerOpen(page);
		// A fixed bar at the bottom of the sidebar, and not the current page.
		const row = await homeRow(page).boundingBox();
		expect(row?.height ?? 0).toBeGreaterThanOrEqual(44);
		expect((row?.y ?? 0) + (row?.height ?? 0)).toBeGreaterThan(844 - 20);
		expect((row?.y ?? 0) + (row?.height ?? 0)).toBeLessThanOrEqual(844);
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

test('with the Voice switch off the Talk button is drawn, off, and says where to turn it on', async ({
	page
}) => {
	await fresh(page);
	await expect(box(page)).toBeVisible();
	const bar = page.locator('[data-voicebar]');
	await expect(bar).toHaveText('Off in MuxMaestro Settings');
	// The label only: no voice control that would do nothing.
	await expect(bar.locator('button')).toHaveCount(0);
	const talk = page.locator('[data-primary]');
	await expect(talk).toHaveText('Talk');
	await expect(talk).toBeDisabled();

	// A tap opens no microphone and sends nothing.
	let asked = 0;
	await page.exposeFunction('__asked', () => (asked += 1));
	await page.evaluate(() => {
		navigator.mediaDevices.getUserMedia = async () => {
			await (window as unknown as { __asked: () => Promise<void> }).__asked();
			throw new Error('no microphone in this test');
		};
	});
	const voiceCalls: string[] = [];
	page.on('request', (request) => {
		if (request.url().includes('/api/voice')) voiceCalls.push(request.url());
	});
	await talk.click({ force: true });
	await page.waitForTimeout(300);
	expect(asked).toBe(0);
	expect(voiceCalls).toEqual([]);

	// Typing is untouched: with text the button is Send, and it sends.
	await box(page).fill('what needs me?');
	await expect(talk).toHaveCount(0);
	await page.getByRole('button', { name: /^Send(ing)?$/ }).click();
	await expect(said(page).locator('.a').last()).toHaveText(
		'2 threads need you: acme-app · checkout-fix, billing · proration.'
	);

	// The switch is turned on at the Mac: the controls come alive with no reload.
	await page.request.post('/__fixture/capability?name=voice&on=1');
	await expect(talk).toBeEnabled();
	await expect(bar.getByRole('button', { name: 'Auto' })).toBeVisible();
	// And off again.
	await page.request.post('/__fixture/capability?name=voice&on=0');
	await expect(talk).toBeDisabled();
	await expect(bar).toHaveText('Off in MuxMaestro Settings');
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

test('the app sends the pairing token with a Maestro turn', async ({ page }) => {
	await fresh(page);
	await box(page).fill('what needs me?');
	const sent = page.waitForRequest((request) => request.url().endsWith('/api/manager/text'));
	await submit(page);
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

test('the Maestro status is drawn while a message cannot go to it', async ({ page }) => {
	await fresh(page);
	await page.request.post('/__fixture/manager-status?value=waiting');
	await page.reload();
	const status = page.locator('[data-status]');
	await expect(status).toHaveText('Maestro is waiting on a prompt');
	await expect(status).toHaveAttribute('data-status', 'waiting');

	await page.request.post('/__fixture/manager-status?value=busy');
	await page.reload();
	await expect(status).toHaveText('Maestro is busy');
	await box(page).fill('what needs me?');
	await submit(page);
	await expect(page.getByRole('alert')).toHaveText('Maestro is busy');
	await expect(box(page)).toHaveValue('what needs me?');

	// Running, but its pane's state is not known: not idle.
	await page.request.post('/__fixture/manager-status?value=unknown');
	await page.reload();
	await expect(status).toHaveText('Maestro is not ready');
	await box(page).fill('what needs me?');
	await submit(page);
	await expect(page.getByRole('alert')).toHaveText('Maestro is not ready');

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
	await submit(page);
	await submit(page);
	await expect(said(page).locator('.a').last()).toHaveText(reply);
	expect(turns).toBe(0);
	await expect(box(page)).toHaveValue('and after that?');

	// The turn is over: now it sends.
	await expect(page.getByRole('button', { name: /^Send(ing)?$/ })).toBeEnabled();
	await submit(page);
	await expect(said(page).locator('.u').last()).toHaveText('and after that?');
	expect(turns).toBe(1);
});

test('a message over the size limit says so and is given back', async ({ page }) => {
	await fresh(page);
	const long = 'a'.repeat(8193);
	await box(page).fill(long);
	await submit(page);
	// The phone counts the bytes itself: it says so before anything is sent.
	await expect(page.getByRole('alert')).toHaveText('Too long by 1 byte');
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

test('the Maestro page is its thread: left-aligned rows and the Chat/Terminal toggle', async ({
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

test('the Maestro thread shows tool lines and user turns like any chat', async ({ page }) => {
	await fresh(page);
	await box(page).fill('what needs me?');
	await submit(page);
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

/** How much of the board shows under the footer, in pixels. */
const boardHeight = async (page: Page): Promise<number> =>
	Math.round((await sheet(page).boundingBox())?.height ?? 0);
const footTop = async (page: Page): Promise<number> => (await foot(page).boundingBox())?.y ?? 0;
const settled = async (page: Page, stop: string): Promise<void> => {
	await expect(sheet(page)).toHaveAttribute('data-stop', stop);
	await page.waitForTimeout(450);
};

test('the board is under the footer: off screen at rest, then open, then 70% tall', async ({
	page
}) => {
	await fresh(page);
	// Rest: the footer is the last thing on screen, and the board has no height.
	await expect(sheet(page)).toHaveAttribute('data-stop', '0');
	expect(await boardHeight(page)).toBe(0);
	const rest = await foot(page).boundingBox();
	expect(Math.round((rest?.y ?? 0) + (rest?.height ?? 0))).toBe(844);
	await expect(sheet(page)).toHaveAttribute('inert', '');
	// The grabber on its top edge says what is under it.
	await expect(grip(page)).toContainText('2 need you · 1 review · 2 updates');
	const grab = await grip(page).boundingBox();
	expect(Math.abs((grab?.y ?? 0) - (rest?.y ?? 0))).toBeLessThan(3);
	const thread = (await said(page).boundingBox())?.height ?? 0;

	// Open: the footer itself has moved up, and the first cards show below it.
	await openBoard(page, 1);
	const open = await boardHeight(page);
	expect(open).toBe(Math.round(844 * 0.3));
	expect(Math.round(await footTop(page))).toBe(Math.round((rest?.y ?? 0) - open));
	const board = await sheet(page).boundingBox();
	const raised = await foot(page).boundingBox();
	// The board starts where the footer ends, and ends at the bottom of the screen.
	expect(Math.round(board?.y ?? 0)).toBe(Math.round((raised?.y ?? 0) + (raised?.height ?? 0)));
	expect(Math.round((board?.y ?? 0) + (board?.height ?? 0))).toBe(844);
	await expect(page.locator('a.item[data-thread="localhost:1"]')).toBeInViewport();
	// The text box moved with the footer and is still on screen; the thread got shorter.
	await expect(box(page)).toBeInViewport();
	await expect(page.locator('[data-voicebar]')).toBeInViewport();
	expect((await said(page).boundingBox())?.height ?? 0).toBeLessThan(thread - open + 2);

	// Tall: the board fills 70% of the screen.
	await grip(page).click();
	await settled(page, '2');
	expect(await boardHeight(page)).toBeGreaterThan(560);
	expect(await boardHeight(page)).toBeLessThanOrEqual(Math.round(844 * 0.7));
	await expect(box(page)).toBeInViewport();
	// The counters stay where they are.
	await expect(page.locator('.chip').first()).toBeInViewport();

	// From the top the grabber goes back to rest.
	await grip(page).click();
	await settled(page, '0');
	expect(await boardHeight(page)).toBe(0);
	expect(await foot(page).boundingBox()).toEqual(rest);
});

test('a swipe up on the footer raises it; a swipe down steps back', async ({ page }) => {
	await fresh(page);
	const rest = await footTop(page);
	// On the voice controls, not the grabber: the whole footer is the handle.
	const bar = await page.locator('[data-voicebar]').boundingBox();
	const x = 195;
	const y = (bar?.y ?? 0) + 8;

	// It follows the finger before it settles.
	await dragStart(page, [x, y], [x, y - 120]);
	expect(await footTop(page)).toBeLessThan(rest - 90);
	expect(await footTop(page)).toBeGreaterThan(rest - 125);
	expect(await boardHeight(page)).toBeGreaterThan(90);
	await page.mouse.up();
	await settled(page, '1');

	// A second swipe up on the footer pulls it to the tall stop.
	let top = await footTop(page);
	await drag(page, [x, top + 40], [x, top - 60]);
	await settled(page, '2');

	// Down steps back one stop at a time.
	top = await footTop(page);
	await drag(page, [x, top + 40], [x, top + 160]);
	await settled(page, '1');
	top = await footTop(page);
	await drag(page, [x, top + 40], [x, top + 160]);
	await settled(page, '0');
	expect(await footTop(page)).toBe(rest);

	// A small move springs back, and a swipe down at rest does nothing.
	await drag(page, [x, y], [x, y - 14]);
	await settled(page, '0');
	await drag(page, [x, y], [x, y + 60]);
	await settled(page, '0');
	expect(await footTop(page)).toBe(rest);
	expect(await boardHeight(page)).toBe(0);
});

test('a drag on a footer control moves the drawer and does not press it; a tap presses it', async ({
	page
}) => {
	await fresh(page);
	// A drag that starts on the grabber raises the footer one stop, not two.
	const grab = await grip(page).boundingBox();
	const gx = (grab?.x ?? 0) + (grab?.width ?? 0) / 2;
	const gy = (grab?.y ?? 0) + (grab?.height ?? 0) / 2;
	await drag(page, [gx, gy], [gx, gy - 90]);
	await settled(page, '1');
	// A drag that starts on Send moves the drawer and sends nothing.
	let turns = 0;
	page.on('request', (request) => {
		if (request.url().endsWith('/api/manager/text')) turns += 1;
	});
	await box(page).fill('what needs me?');
	await page.locator('body').click({ position: { x: 195, y: 200 } });
	const send = await page.getByRole('button', { name: /^Send(ing)?$/ }).boundingBox();
	const sx = (send?.x ?? 0) + (send?.width ?? 0) / 2;
	const sy = (send?.y ?? 0) + (send?.height ?? 0) / 2;
	await drag(page, [sx, sy], [sx, sy + 120]);
	await settled(page, '0');
	expect(turns).toBe(0);
	await expect(box(page)).toHaveValue('what needs me?');
	// A tap on it still sends.
	await page.getByRole('button', { name: /^Send(ing)?$/ }).click();
	await expect(said(page).locator('.a').last()).toContainText('2 threads need you');
	expect(turns).toBe(1);
});

test('typing does not move the drawer, and with the keyboard up the board stays shut', async ({
	page
}) => {
	await fresh(page);
	const rest = await footTop(page);
	// A drag that begins in the text box is not the drawer's.
	const input = await box(page).boundingBox();
	const ix = (input?.x ?? 0) + 60;
	const iy = (input?.y ?? 0) + (input?.height ?? 0) / 2;
	await drag(page, [ix, iy], [ix, iy - 140]);
	await settled(page, '0');
	expect(await footTop(page)).toBe(rest);

	// Open the board, then take the keyboard: the board shuts.
	await openBoard(page, 1);
	await box(page).focus();
	await settled(page, '0');
	expect(await boardHeight(page)).toBe(0);
	// While the box has the keyboard, neither the grabber nor a swipe opens it.
	await grip(page).dispatchEvent('click');
	await expect(sheet(page)).toHaveAttribute('data-stop', '0');
	const bar = await page.locator('[data-voicebar]').boundingBox();
	await drag(page, [195, (bar?.y ?? 0) + 8], [195, (bar?.y ?? 0) - 110]);
	await settled(page, '0');
	await box(page).pressSequentially('what needs me?');
	await expect(box(page)).toHaveValue('what needs me?');
	await expect(sheet(page)).toHaveAttribute('data-stop', '0');

	// The keyboard closes: the drawer works again.
	await box(page).blur();
	await grip(page).click();
	await settled(page, '1');
});

test('with the keyboard open the footer sits on the keyboard', async ({ page }) => {
	await fresh(page);
	await expect(box(page)).toBeVisible();
	// A phone's keyboard covers the bottom of the page without making it shorter.
	// Say the visible part is 336px shorter, as the browser would.
	await page.evaluate(() => {
		const visible = window.visualViewport;
		if (!visible) throw new Error('no visual viewport');
		Object.defineProperty(visible, 'height', { configurable: true, get: () => 844 - 336 });
		visible.dispatchEvent(new Event('resize'));
	});
	await box(page).focus();
	const raised = await foot(page).boundingBox();
	expect(Math.round((raised?.y ?? 0) + (raised?.height ?? 0))).toBe(844 - 336);
	expect(await boardHeight(page)).toBe(0);
	// The thread is still there above it, at its latest message.
	await expect(said(page).locator('.a').last()).toBeInViewport();
	await expect(page.locator('.chip').first()).toBeInViewport();

	// The keyboard closes: the footer is back at the bottom.
	await page.evaluate(() => {
		const visible = window.visualViewport;
		if (!visible) throw new Error('no visual viewport');
		Object.defineProperty(visible, 'height', { configurable: true, get: () => 844 });
		visible.dispatchEvent(new Event('resize'));
	});
	await box(page).blur();
	const back = await foot(page).boundingBox();
	expect(Math.round((back?.y ?? 0) + (back?.height ?? 0))).toBe(844);
});

test("the board's list scrolls only at the tall stop, and scrolls back before the drawer steps down", async ({
	page
}) => {
	await fresh(page);
	// Enough cards that the list is longer than the tall board.
	for (const id of [
		'localhost:3',
		'localhost:4',
		'devbox:5',
		'localhost:6',
		'localhost:7',
		'buildbox:8',
		'localhost:9'
	]) {
		await page.request.post(`/__fixture/wait?id=${id}`);
	}
	await expect(grip(page)).toContainText('9 need you');
	const scrolled = (): Promise<number> => sheet(page).evaluate((el) => el.scrollTop);
	const top = async (): Promise<number> => (await sheet(page).boundingBox())?.y ?? 0;

	// Open: a swipe up on the list moves the drawer, not the list.
	await openBoard(page, 1);
	await drag(page, [195, (await top()) + 160], [195, (await top()) + 60]);
	await settled(page, '2');
	expect(await scrolled()).toBe(0);

	// Tall: a swipe up scrolls the list.
	const tall = await top();
	await drag(page, [195, tall + 400], [195, tall + 200]);
	await expect(sheet(page)).toHaveAttribute('data-stop', '2');
	expect(await scrolled()).toBeGreaterThan(120);

	// A swipe down scrolls it back first; the drawer stays tall.
	await drag(page, [195, tall + 200], [195, tall + 520]);
	await expect.poll(scrolled).toBe(0);
	await expect(sheet(page)).toHaveAttribute('data-stop', '2');
	// From the top of the list, the next swipe down steps the drawer back.
	await drag(page, [195, tall + 200], [195, tall + 320]);
	await settled(page, '1');
});

test('the thread shrinks as the footer rises and stays at its latest message', async ({ page }) => {
	await fresh(page);
	const reply = (
		'A long reply to fill the thread. ' + 'More detail follows here. '.repeat(90)
	).trim();
	await page.request.post(
		`/__fixture/mac-turn?text=${encodeURIComponent('summarise everything')}&reply=${encodeURIComponent(reply)}&ms=1`
	);
	await expect(said(page).locator('.a').last()).toHaveText(reply);
	const gap = (): Promise<number> =>
		said(page).evaluate((el) => Math.round(el.scrollHeight - el.scrollTop - el.clientHeight));
	await expect.poll(gap).toBeLessThan(3);
	const before = (await said(page).boundingBox())?.height ?? 0;

	for (const stop of [1, 2] as const) {
		await grip(page).click();
		await settled(page, String(stop));
		// Shorter, and still showing the end of the reply.
		expect((await said(page).boundingBox())?.height ?? 0).toBeLessThan(before);
		await expect.poll(gap).toBeLessThan(3);
	}
	await grip(page).click();
	await settled(page, '0');
	await expect.poll(gap).toBeLessThan(3);
	expect((await said(page).boundingBox())?.height ?? 0).toBe(before);
});

test('a swipe up on the thread at its end raises the footer', async ({ page }) => {
	await fresh(page);
	await expect(said(page).locator('.a').first()).toBeVisible();
	await expect(sheet(page)).toHaveAttribute('data-stop', '0');
	// A swipe down there does nothing to the board.
	await touchDrag(page, [195, 300], [195, 420]);
	await expect(sheet(page)).toHaveAttribute('data-stop', '0');
	await touchDrag(page, [195, 420], [195, 300]);
	await expect(sheet(page)).toHaveAttribute('data-stop', '1');
});

test('the drawer does not fight the sidebar swipe or the toggle', async ({ page }) => {
	await fresh(page);
	await openBoard(page, 1);
	const top = await footTop(page);
	// A sideways drag on the footer, and on the board, opens the sidebar and leaves the drawer alone.
	await drag(page, [60, top + 50], [300, top + 56]);
	await expectDrawerOpen(page);
	await expect(sheet(page)).toHaveAttribute('data-stop', '1');
	await drag(page, [300, 300], [60, 304]);
	await expectDrawerClosed(page);
	const board = (await sheet(page).boundingBox())?.y ?? 0;
	await drag(page, [60, board + 150], [300, board + 156]);
	await expectDrawerOpen(page);
	await expect(sheet(page)).toHaveAttribute('data-stop', '1');
	await drag(page, [300, 300], [60, 304]);
	await expectDrawerClosed(page);
	// The toggle above it still switches.
	await page.locator('[data-tab="main"]').click();
	await expect(page.locator('[data-tab="main"]')).toHaveText(/Terminal\s*⇄/);
	await expect(sheet(page)).toHaveAttribute('data-stop', '1');
});

test('no empty band under the board at any stop', async ({ page }) => {
	await fresh(page);
	for (const stop of ['0', '1', '2']) {
		if (stop !== '0') await grip(page).click();
		await settled(page, stop);
		// The last thing on screen ends where the screen ends, and nothing is taller than it.
		const last = stop === '0' ? await foot(page).boundingBox() : await sheet(page).boundingBox();
		expect(Math.round((last?.y ?? 0) + (last?.height ?? 0))).toBe(844);
		expect(await page.evaluate(() => document.documentElement.scrollHeight)).toBe(844);
	}
	// The bottom inset is counted once: on the footer at rest, on the board when it shows.
	const rule = await page.evaluate(() => {
		const found: string[] = [];
		for (const sheet of [...document.styleSheets]) {
			for (const rule of [...sheet.cssRules]) {
				if (rule instanceof CSSStyleRule && /\.compose\.|\.end\./.test(rule.selectorText)) {
					if (rule.cssText.includes('safe-area-inset-bottom')) found.push(rule.cssText);
				}
			}
		}
		return found.join('\n');
	});
	expect(rule).toContain('var(--board');
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
	// And the end of it is not hidden under the footer.
	await said(page).evaluate((el) => (el.scrollTop = el.scrollHeight));
	const end = await last.boundingBox();
	expect((end?.y ?? 0) + (end?.height ?? 0)).toBeLessThanOrEqual((await footTop(page)) + 1);
});

test('the waiting state is shown once, with a way to the terminal', async ({ page }) => {
	await fresh(page);
	await page.request.post('/__fixture/manager-status?value=waiting');
	await page.reload();
	await expect(page.locator('[data-status]')).toHaveText('Maestro is waiting on a prompt');
	await expect(page.getByText('Maestro is waiting on a prompt')).toHaveCount(1);
	// A refused send says it once too, not beside the status.
	await box(page).fill('what needs me?');
	await submit(page);
	await expect(page.getByRole('alert')).toHaveText('Maestro is waiting on a prompt');
	await expect(page.getByText('Maestro is waiting on a prompt')).toHaveCount(1);

	// The prompt is in the pane: one tap shows the terminal.
	await page.getByRole('button', { name: 'Terminal', exact: true }).click();
	await expect(page.locator('[data-tab="main"]')).toHaveText(/Terminal\s*⇄/);
	await expect(page.locator('[data-view="terminal"]')).toContainText('Do you want to proceed?');
});

test('a waiting state that ends on the Mac ends on the phone, with no reload', async ({ page }) => {
	await fresh(page);
	await page.request.post('/__fixture/manager-status?value=waiting');
	await page.reload();
	await expect(page.locator('[data-status]')).toHaveText('Maestro is waiting on a prompt');
	// A send is refused, and the refusal is on screen.
	await box(page).fill('what needs me?');
	await submit(page);
	await expect(page.getByRole('alert')).toHaveText('Maestro is waiting on a prompt');

	// The prompt ends on the Mac (answered, or cancelled). The next board
	// brings the status with it: nothing on the phone still says waiting.
	await page.request.post('/__fixture/manager-status?value=idle');
	await expect(page.getByText('Maestro is waiting on a prompt')).toHaveCount(0);
	await expect(page.getByRole('alert')).toHaveCount(0);
	await expect(page.locator('[data-status]')).toHaveCount(0);
	// The text that was given back goes through now.
	await expect(box(page)).toHaveValue('what needs me?');
	await submit(page);
	await expect(said(page).locator('.a').last()).toContainText('2 threads need you');
});

test('sidebar: the Maestro bar stays at the bottom, and the list scrolls above it', async ({
	page
}) => {
	await fresh(page);
	await page.getByRole('button', { name: 'Menu' }).click();
	await expectDrawerOpen(page);
	const list = drawer(page).locator('.scroll');
	const bar = async (): Promise<{ y: number; bottom: number }> => {
		const box = await homeRow(page).boundingBox();
		return { y: box?.y ?? 0, bottom: (box?.y ?? 0) + (box?.height ?? 0) };
	};
	const before = await bar();

	// Refresh and the grouping tabs stay at the top, above the list.
	const tabs = await drawer(page).getByRole('tablist', { name: 'Group by' }).boundingBox();
	const refresh = await drawer(page).getByRole('button', { name: 'Refresh' }).boundingBox();
	const area = await list.boundingBox();
	expect((tabs?.y ?? 99) + (tabs?.height ?? 0)).toBeLessThanOrEqual((area?.y ?? 0) + 8);
	expect(refresh?.y ?? 999).toBeLessThan(area?.y ?? 0);
	// The list ends above the bar: no row can sit under it.
	expect((area?.y ?? 0) + (area?.height ?? 0)).toBeLessThanOrEqual(before.y);

	// Scrolled to its end, the last host card is whole and above the bar; the bar has not moved.
	await list.evaluate((el) => (el.scrollTop = el.scrollHeight));
	expect(await list.evaluate((el) => el.scrollTop)).toBeGreaterThan(200);
	const last = await drawer(page).locator('[data-host]').last().boundingBox();
	expect((last?.y ?? 0) + (last?.height ?? 0)).toBeLessThanOrEqual(before.y);
	expect(await bar()).toEqual(before);
	await expect(homeRow(page)).toBeInViewport();
	// On the home it is the current page.
	await expect(homeRow(page)).toHaveAttribute('aria-current', 'page');
});

test('sidebar: the Maestro bar clears the home indicator', async ({ page }) => {
	await fresh(page);
	await page.getByRole('button', { name: 'Menu' }).click();
	await expectDrawerOpen(page);
	const padding = await drawer(page)
		.locator('.dbar')
		.evaluate((el) => getComputedStyle(el).paddingBottom);
	// 8px plus the bottom inset, which is 0 in this browser.
	expect(padding).toBe('8px');
	const rule = await page.evaluate(() => {
		for (const sheet of [...document.styleSheets]) {
			for (const rule of [...sheet.cssRules]) {
				if (rule instanceof CSSStyleRule && rule.selectorText.includes('.dbar')) {
					return rule.cssText;
				}
			}
		}
		return '';
	});
	expect(rule).toContain('safe-area-inset-bottom');
});
