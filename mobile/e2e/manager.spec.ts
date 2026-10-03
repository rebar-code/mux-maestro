import { expect, test, type Page } from '@playwright/test';
import {
	drag,
	drawer,
	expectDrawerClosed,
	expectDrawerOpen,
	fresh,
	threadPath,
	TOKEN,
	TOKEN_HEADER
} from './helpers';

const said = (page: Page) => page.locator('[data-said]');
const box = (page: Page) => page.getByRole('textbox', { name: 'Ask the manager' });
const offBox = (page: Page) => page.getByRole('textbox', { name: 'Off in MuxMaestro Settings' });
const homeRow = (page: Page) => drawer(page).locator('[data-home]');
const review = (page: Page) => page.locator('[data-review]');

test('the app opens on the manager home', async ({ page }) => {
	await fresh(page);
	await expect(page.locator('.chip').first()).toHaveText('2 need you');
	await expect(said(page).locator('.m')).toHaveText(
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
	// With nothing typed there is nothing to send: the button is Talk.
	await expect(page.getByRole('button', { name: '↑ Send' })).toHaveCount(0);
	await box(page).fill('what needs me?');
	const sent = page.waitForRequest((request) => request.url().endsWith('/api/manager/text'));
	await page.getByRole('button', { name: '↑ Send' }).click();
	const request = await sent;
	expect(request.method()).toBe('POST');
	expect(request.headers()['x-muxmaestro']).toBe('1');
	expect(request.postDataJSON()).toEqual({ text: 'what needs me?' });

	await expect(box(page)).toHaveValue('');
	await expect(said(page).locator('.u')).toHaveText('what needs me?');
	await expect(said(page).locator('.m').last()).toHaveText(
		'2 threads need you: acme-app · checkout-fix, billing · proration.'
	);
	// The turn is in the chat now: a reload shows the same lines.
	await page.reload();
	await expect(said(page).locator('.u')).toHaveText('what needs me?');
	await expect(said(page).locator('.m').last()).toHaveText(
		'2 threads need you: acme-app · checkout-fix, billing · proration.'
	);
	await expect(page.getByRole('alert')).toHaveCount(0);
});

test('Enter sends too', async ({ page }) => {
	await fresh(page);
	await box(page).fill('what needs me?');
	await box(page).press('Enter');
	await expect(said(page).locator('.m').last()).toContainText('2 threads need you');
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
	await expect(said(page).locator('.m').last()).toContainText('2 threads need you');
	await expect(page.getByRole('alert')).toHaveCount(0);
});

test('a turn typed on the Mac shows on the phone, and holds Send until it ends', async ({
	page
}) => {
	await fresh(page);
	await expect(said(page).locator('.m')).toHaveCount(1);
	await box(page).fill('and after that?');
	const reply = 'All four are still running. ' + 'Nothing new. '.repeat(12).trim();
	await page.request.post(
		`/__fixture/mac-turn?text=${encodeURIComponent('how are the builds?')}&reply=${encodeURIComponent(reply)}`
	);
	await expect(said(page).locator('.u')).toHaveText('how are the builds?');
	await expect(page.getByRole('button', { name: '↑ Send' })).toBeDisabled();
	await expect(said(page).locator('.m').last()).toHaveText(reply);
	await expect(page.getByRole('button', { name: '↑ Send' })).toBeEnabled();
	await expect(box(page)).toHaveValue('and after that?');
});

test('a "Needs you" card opens its thread', async ({ page }) => {
	await fresh(page);
	await page.locator('a.item[data-thread="localhost:1"]').click();
	await expect(page).toHaveURL(/\/t\/localhost(:|%3A)1$/);
	await expect(page.locator('.tbar .title b')).toHaveText('acme-app · checkout-fix');
	await expect(page.locator('.u').first()).toHaveText(
		'fix the failing checkout test and open a PR'
	);
});

test('a review card opens its thread', async ({ page }) => {
	await fresh(page);
	await review(page).locator('a.open').click();
	await expect(page).toHaveURL(/\/t\/localhost(:|%3A)9$/);
	await expect(page.locator('.tbar .title b')).toHaveText('billing · invoices-pdf');
});

test('a left swipe dismisses a review item, on the Mac too', async ({ page }) => {
	await fresh(page);
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
	await expect(page.locator('.sect').first()).toHaveText('Needs you · 2');
	await expect(review(page)).toHaveCount(0);
});

test('the dismiss button does the same as the swipe', async ({ page }) => {
	await fresh(page);
	await page.getByRole('button', { name: 'Dismiss billing · invoices-pdf' }).click();
	await expect(review(page)).toHaveCount(0);
	await page.reload();
	await expect(page.locator('.sect').first()).toHaveText('Needs you · 2');
	await expect(review(page)).toHaveCount(0);
});

test('a right swipe on the home still opens the sidebar, over a review card too', async ({
	page
}) => {
	await fresh(page);
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
	await expect(page.getByRole('button', { name: 'Talk to the manager' })).toBeVisible();
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
	await expect(talk).toHaveText('🎙 Talk');
	await expect(talk).toBeDisabled();
	await expect(page.locator('[data-orb]')).toBeDisabled();
	await expect(page.locator('[data-orb]')).toHaveAccessibleName('Talk to the manager');

	// A tap on either opens no microphone and sends nothing.
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
	await page.locator('[data-orb]').click({ force: true });
	await page.waitForTimeout(300);
	expect(asked).toBe(0);
	expect(voiceCalls).toEqual([]);

	// Typing is untouched: with text the button is Send, and it sends.
	await box(page).fill('what needs me?');
	await expect(talk).toHaveCount(0);
	await page.getByRole('button', { name: '↑ Send' }).click();
	await expect(said(page).locator('.m').last()).toHaveText(
		'2 threads need you: acme-app · checkout-fix, billing · proration.'
	);

	// The switch is turned on at the Mac: the controls come alive with no reload.
	await page.request.post('/__fixture/capability?name=voice&on=1');
	await expect(talk).toBeEnabled();
	await expect(page.locator('[data-orb]')).toBeEnabled();
	await expect(bar).toContainText('Start talking');
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

test('the app sends the pairing token with a manager turn', async ({ page }) => {
	await fresh(page);
	await box(page).fill('what needs me?');
	const sent = page.waitForRequest((request) => request.url().endsWith('/api/manager/text'));
	await box(page).press('Enter');
	expect((await sent).headers()['x-muxmaestro-token']).toBe(TOKEN);
	await expect(said(page).locator('.m').last()).toContainText('2 threads need you');
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
	await expect(said(page).locator('.m').last()).toHaveText(reply);
	expect(turns).toBe(0);
	await expect(box(page)).toHaveValue('and after that?');

	// The turn is over: now Enter sends.
	await expect(page.getByRole('button', { name: '↑ Send' })).toBeEnabled();
	await box(page).press('Enter');
	await expect(said(page).locator('.u')).toHaveText('and after that?');
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
