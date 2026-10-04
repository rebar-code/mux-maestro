import { expect, test } from '@playwright/test';
import { drawer, forget, fresh, pairingLink, reset, TOKEN } from './helpers';

const stored = (page: import('@playwright/test').Page): Promise<string | null> =>
	page.evaluate(() => localStorage.getItem('mm.token'));

test('the pairing link stores the token and leaves no trace in the address', async ({ page }) => {
	await reset(page);
	await forget(page);
	const sent: (string | undefined)[] = [];
	page.on('request', (request) => {
		if (new URL(request.url()).pathname.startsWith('/api/')) {
			sent.push(request.headers()['x-muxmaestro-token']);
		}
	});
	await page.goto(pairingLink());
	await expect(page.locator('.chip').first()).toHaveText('2 need you');
	expect(page.url()).not.toContain('pair');
	expect(page.url()).not.toContain('#');
	expect(await stored(page)).toBe(TOKEN);
	// Every API request carried it, the first one included.
	expect(sent.length).toBeGreaterThan(0);
	expect(sent.every((value) => value === TOKEN)).toBe(true);

	// It lasts: a plain reopen needs no link.
	await page.goto('/');
	await expect(page.locator('.chip').first()).toHaveText('2 need you');
});

test('static files need no token', async ({ page }) => {
	expect((await page.request.get('/')).ok()).toBe(true);
	expect((await page.request.get('/manifest.webmanifest')).ok()).toBe(true);
	expect((await page.request.get('/api/threads')).status()).toBe(401);
});

test('no token: "Not paired"; pasting the link pairs and shows the lists', async ({ page }) => {
	await reset(page);
	await forget(page);
	await page.goto('/');
	await expect(page.getByRole('heading', { name: 'Not paired' })).toBeVisible();
	await expect(page.locator('.tbar')).toHaveCount(0);
	await expect(drawer(page)).toHaveCount(0);

	const field = page.getByRole('textbox', { name: 'Pairing link' });
	await expect(field).toHaveCSS('font-size', '16px');
	for (const target of [field, page.getByRole('button', { name: 'Pair' })]) {
		expect((await target.boundingBox())?.height).toBeGreaterThanOrEqual(44);
	}

	await field.fill(`https://devmac.example.ts.net:7433/#pair=${TOKEN}`);
	await page.getByRole('button', { name: 'Pair' }).click();
	await expect(page.locator('.chip').first()).toHaveText('2 need you');
	await expect(page.getByRole('heading', { name: 'Not paired' })).toHaveCount(0);
	expect(await stored(page)).toBe(TOKEN);

	// The stream runs on the new token: a pushed change shows.
	await page.request.post('/__fixture/wait?id=localhost:3');
	await expect(page.locator('.chip').first()).toHaveText('3 need you');
});

test('a bare token pairs too', async ({ page }) => {
	await reset(page);
	await forget(page);
	await page.goto('/');
	await page.getByRole('textbox', { name: 'Pairing link' }).fill(TOKEN);
	await page.getByRole('textbox', { name: 'Pairing link' }).press('Enter');
	await expect(page.locator('.chip').first()).toHaveText('2 need you');
});

test('a wrong token marks the field and stays', async ({ page }) => {
	await reset(page);
	await forget(page);
	await page.goto('/');
	const field = page.getByRole('textbox', { name: 'Pairing link' });

	await field.fill('wrong-token-value');
	await page.getByRole('button', { name: 'Pair' }).click();
	await expect(field).toHaveAttribute('aria-invalid', 'true');
	await expect(field).toHaveCSS('border-top-color', 'rgb(248, 81, 73)');
	await expect(page.getByRole('heading', { name: 'Not paired' })).toBeVisible();
	expect(await stored(page)).toBeNull();

	// Text with no token in it is refused without asking the server.
	await field.fill('not a link');
	await expect(field).toHaveAttribute('aria-invalid', 'false');
	await page.getByRole('button', { name: 'Pair' }).click();
	await expect(field).toHaveAttribute('aria-invalid', 'true');
});

test('a token the server rotated away: "Not paired", and cached lists stay hidden', async ({
	page
}) => {
	await fresh(page);
	await expect(page.locator('.chip').first()).toHaveText('2 need you');
	// Rotating also drops the stream; the reconnect is refused.
	await page.request.post('/__fixture/rotate?value=another-token');
	await expect(page.getByRole('heading', { name: 'Not paired' })).toBeVisible();
	await expect(page.getByText('need you')).toHaveCount(0);
	expect(await stored(page)).toBeNull();

	// Still so after a reload, though the lists are cached.
	await page.reload();
	await expect(page.getByRole('heading', { name: 'Not paired' })).toBeVisible();
	expect(await page.evaluate(() => localStorage.getItem('mm.threads'))).not.toBeNull();
	await expect(page.getByText('need you')).toHaveCount(0);

	await page.getByRole('textbox', { name: 'Pairing link' }).fill('another-token');
	await page.getByRole('button', { name: 'Pair' }).click();
	await expect(page.locator('.chip').first()).toHaveText('2 need you');
});

test('a pairing link opened over the running app pairs it', async ({ page }) => {
	await reset(page);
	await forget(page);
	await page.goto('/');
	await expect(page.getByRole('heading', { name: 'Not paired' })).toBeVisible();
	// Same page, new fragment: no reload happens.
	await page.evaluate((hash) => (location.hash = hash), `pair=${TOKEN}`);
	await expect(page.locator('.chip').first()).toHaveText('2 need you');
	expect(page.url()).not.toContain('pair');
});

test('the live stream delivers changes and reconnects after a drop', async ({ page }) => {
	await fresh(page);
	await expect(page.locator('.chip').first()).toHaveText('2 need you');
	await page.request.post('/__fixture/wait?id=localhost:3');
	await expect(page.locator('.chip').first()).toHaveText('3 need you');

	let opened = 0;
	page.on('request', (request) => {
		if (request.url().endsWith('/api/events')) opened += 1;
	});
	await page.request.post('/__fixture/drop');
	await expect.poll(() => opened, { timeout: 8000 }).toBe(1);
	await page.request.post('/__fixture/wait?id=localhost:4');
	await expect(page.locator('.chip').first()).toHaveText('4 need you');
});
