import { mkdirSync } from 'node:fs';
import { expect, test, type Page } from '@playwright/test';
import { fresh, TOKEN_HEADER, WIDTH } from './helpers';

/** A fake keygate origin: nothing real answers it, the test serves its page. */
const ORIGIN = 'https://keygate.example.ts.net';
const ID = 'ab12cd34';

const tab = (page: Page, name: string) => page.locator(`[data-tab="${name}"]`);
const pageOf = (page: Page, name: string) => page.locator(`[data-page="${name}"]`);
const row = (page: Page, id = ID) => page.locator(`[data-review="keygate:${id}"]`);
const approve = (page: Page, id = ID) => row(page, id).locator('[data-keygate]');

/** Show the Board tab, and let the pager come to rest on it. */
async function openBoard(page: Page): Promise<void> {
	await tab(page, 'board').click();
	await expect(pageOf(page, 'board')).not.toHaveAttribute('inert', '');
	await expect
		.poll(() =>
			page.locator('.track').evaluate((el) => Math.round(el.getBoundingClientRect().left))
		)
		.toBe(-WIDTH);
}

/** A keygate review row, as the Mac sends it. No origin: keygate has none. */
async function raise(
	page: Page,
	{ id = ID, origin = ORIGIN as string | null, thread = '' } = {}
): Promise<void> {
	const query = new URLSearchParams({ id });
	if (origin !== null) query.set('origin', origin);
	if (thread) query.set('thread', thread);
	await page.request.post(`/__fixture/keygate?${query}`, { headers: TOKEN_HEADER });
}

/** Screenshots are taken only when SHOTS names a directory outside the repo. */
async function shot(page: Page, name: string): Promise<void> {
	const dir = process.env.SHOTS;
	if (!dir) return;
	mkdirSync(dir, { recursive: true });
	await page.waitForTimeout(250);
	await page.screenshot({ path: `${dir}/${name}.png` });
}

test.describe('keygate cards', () => {
	test('a keygate row links to keygate’s page for that request', async ({ page }) => {
		await fresh(page);
		await raise(page);
		await openBoard(page);
		await expect(row(page)).toContainText('wants STRIPE_SECRET_KEY to run the migration');
		const link = approve(page);
		await expect(link).toHaveText('Approve with Face ID');
		await expect(link).toHaveAttribute('href', `${ORIGIN}/?id=${ID}`);
		await expect(link).toHaveAttribute('target', '_blank');
		await expect(link).toHaveAttribute('rel', 'noopener noreferrer');
		expect((await link.boundingBox())?.height).toBeGreaterThanOrEqual(44);
		await shot(page, 'keygate-card');
	});

	test('a tap opens keygate in a new tab and sends the Mac nothing', async ({ page }) => {
		await page
			.context()
			.route(`${ORIGIN}/**`, (route) =>
				route.fulfill({ contentType: 'text/html', body: '<title>keygate</title>keygate' })
			);
		await fresh(page);
		await raise(page, { thread: 'localhost:9' });
		await openBoard(page);
		const posts: string[] = [];
		page.on('request', (request) => {
			if (request.method() === 'POST') posts.push(new URL(request.url()).pathname);
		});
		const before = page.url();
		const [tabOpened] = await Promise.all([
			page.context().waitForEvent('page'),
			approve(page).click()
		]);
		await tabOpened.waitForLoadState();
		expect(tabOpened.url()).toBe(`${ORIGIN}/?id=${ID}`);
		// noopener: keygate's page cannot reach back into this one.
		expect(await tabOpened.evaluate(() => window.opener)).toBeNull();
		// The app stays where it was: the tap did not open the row's thread.
		expect(page.url()).toBe(before);
		expect(posts.filter((path) => path.startsWith('/api/'))).toEqual([]);
	});

	test('no link when keygate has no origin', async ({ page }) => {
		await fresh(page);
		await raise(page, { origin: null });
		await openBoard(page);
		await expect(row(page)).toBeVisible();
		await expect(approve(page)).toHaveCount(0);
	});

	test('no link for an origin or id that fails the check', async ({ page }) => {
		await fresh(page);
		const bad = [
			{ id: 'aa01', origin: 'http://keygate.example.ts.net' },
			{ id: 'aa02', origin: 'javascript:alert(1)' },
			{ id: 'aa03', origin: `${ORIGIN}/approve` },
			{ id: 'aa04', origin: 'https://user@keygate.example.ts.net' },
			{ id: 'AA05', origin: ORIGIN },
			{ id: 'aa06&next=x', origin: ORIGIN }
		];
		for (const card of bad) await raise(page, card);
		await openBoard(page);
		for (const { id } of bad) {
			await expect(row(page, id)).toBeVisible();
			await expect(approve(page, id)).toHaveCount(0);
		}
		// A plain review row has no link either.
		await expect(page.locator('[data-review="billing:invoices-pdf"] [data-keygate]')).toHaveCount(
			0
		);
	});
});
