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
const box = (page: Page) => page.getByRole('textbox', { name: 'Ask the Maestro' });
const review = (page: Page) => page.locator('[data-review]');

test('the app opens on the Maestro home', async ({ page }) => {
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

test('a message to the Maestro streams its reply onto the home', async ({ page }) => {
	await fresh(page);
	// With nothing typed there is nothing to send.
	await expect(page.getByRole('button', { name: '↑ Send' })).toBeDisabled();
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
	await expect(page.getByRole('alert')).toHaveText('Maestro is waiting on a prompt');
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

test('the Maestro row in the sidebar opens the home', async ({ page }) => {
	await fresh(page, threadPath('localhost:1'));
	await page.getByRole('button', { name: 'Menu' }).click();
	await drawer(page).getByText('✦ Maestro').click();
	await expect(page).toHaveURL(/\/$/);
	await expectDrawerClosed(page);
	await expect(box(page)).toBeVisible();
});

test('with the Maestro switch off the home and its row are hidden', async ({ page }) => {
	await fresh(page);
	await expect(box(page)).toBeVisible();
	await page.request.post('/__fixture/capability?name=manager&on=0');
	await expect(box(page)).toHaveCount(0);
	await expect(said(page)).toHaveCount(0);
	await expect(review(page)).toHaveCount(0);
	await expect(page.getByRole('button', { name: 'Talk to the Maestro' })).toHaveCount(0);
	await expect(page.locator('[data-voicebar]')).toHaveCount(0);
	// The threads that wait are still listed: they come from the thread list.
	await expect(page.locator('.sect').first()).toHaveText('Needs you · 2');
	expect(
		await page.evaluate(
			async (headers) => (await fetch('/api/manager', { headers })).status,
			TOKEN_HEADER
		)
	).toBe(403);
	await page.getByRole('button', { name: 'Menu' }).click();
	await expect(drawer(page).getByText('✦ Maestro')).toHaveCount(0);

	// Off at first paint too: nothing of the manager is drawn from the cache.
	await page.reload();
	await expect(page.locator('.sect').first()).toHaveText('Needs you · 2');
	await expect(box(page)).toHaveCount(0);
});

test('with the Voice switch off its controls are hidden and typing still works', async ({
	page
}) => {
	await fresh(page);
	await expect(box(page)).toBeVisible();
	await expect(page.locator('[data-voicebar]')).toHaveCount(0);
	await expect(page.locator('[data-orb]')).toHaveCount(0);
	await expect(page.locator('[data-primary]')).toHaveCount(0);
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
	await box(page).press('Enter');
	await expect(page.getByRole('alert')).toHaveText('Maestro is busy');
	await expect(box(page)).toHaveValue('what needs me?');

	// Running, but its pane's state is not known: not idle.
	await page.request.post('/__fixture/manager-status?value=unknown');
	await page.reload();
	await expect(status).toHaveText('Maestro is not ready');
	await box(page).fill('what needs me?');
	await box(page).press('Enter');
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
