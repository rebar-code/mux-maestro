import { expect, test } from '@playwright/test';
import {
	drag,
	dragStart,
	drawer,
	expectDrawerClosed,
	expectDrawerOpen,
	fresh,
	threadPath
} from './helpers';

const LOCAL = 'localhost:1';
const REMOTE = 'devbox:2';

test('the drawer opens a thread, closes itself and marks the row', async ({ page }) => {
	await fresh(page);
	await page.getByRole('button', { name: 'Menu' }).click();
	await drawer(page).locator(`[data-thread="${LOCAL}"]`).click();
	await expect(page).toHaveURL(/\/t\/localhost(:|%3A)1$/);
	await expectDrawerClosed(page);
	await expect(page.locator('.tbar .title b')).toHaveText('acme-app · checkout-fix');

	await page.getByRole('button', { name: 'Menu' }).click();
	await expect(drawer(page).locator(`[data-thread="${LOCAL}"]`)).toHaveAttribute(
		'aria-current',
		'page'
	);
	await drawer(page).getByText('Manager').click();
	await expect(page).toHaveURL(/\/$/);
});

test('header: tinted with the host colour and names the host', async ({ page }) => {
	await fresh(page, threadPath(REMOTE));
	const header = page.locator('.tbar');
	await expect(header).toHaveCSS('border-bottom-color', 'rgb(245, 166, 35)');
	await expect(header.locator('.hchip')).toHaveText('devbox');
	await expect(header.locator('.hchip')).toHaveCSS('background-color', 'rgb(245, 166, 35)');
	await expect(header.locator('.title span')).toContainText('needs you');
	await expect(page.getByRole('button', { name: 'Find' })).toBeDisabled();
});

test('the first tab switches between chat and terminal', async ({ page }) => {
	await fresh(page, threadPath(LOCAL));
	const tab = page.locator('[data-tab="main"]');
	await expect(tab).toHaveText(/Chat\s*⇄/);
	await expect(page.locator('.u').first()).toHaveText(
		'fix the failing checkout test and open a PR'
	);
	await expect(page.locator('.tool').first()).toHaveText('Read tests/checkout.spec.ts');
	await expect(page.locator('.a')).toHaveCount(3);

	await tab.click();
	await expect(tab).toHaveText(/Terminal\s*⇄/);
	await expect(page.locator('.screen')).toContainText('pnpm exec playwright test');
	await expect(page.locator('.u')).toHaveCount(0);

	await tab.click();
	await expect(tab).toHaveText(/Chat\s*⇄/);
	await expect(page.locator('.u').first()).toBeVisible();
});

test('a remote thread has the terminal only, with no switch', async ({ page }) => {
	await fresh(page, threadPath(REMOTE));
	const tab = page.locator('[data-tab="main"]');
	await expect(tab).toHaveText('Terminal');
	await expect(page.locator('.screen')).toBeVisible();
	await tab.click();
	await expect(tab).toHaveText('Terminal');
	await expect(page.locator('.screen')).toBeVisible();
});

test('a right swipe on the first page opens the drawer', async ({ page }) => {
	await fresh(page, threadPath(LOCAL));
	await expect(page.locator('.u').first()).toBeVisible();
	await drag(page, [60, 500], [300, 505]);
	await expectDrawerOpen(page);
});

test('a left swipe with one page resists and springs back', async ({ page }) => {
	await fresh(page, threadPath(LOCAL));
	await expect(page.locator('.u').first()).toBeVisible();
	await dragStart(page, [300, 500], [100, 500]);
	const x = await page.locator('.track').evaluate((el) => el.getBoundingClientRect().left);
	// 190px of finger travel moves the page a quarter of that.
	expect(x).toBeLessThan(-40);
	expect(x).toBeGreaterThan(-55);
	await page.mouse.up();
	await expect
		.poll(() => page.locator('.track').evaluate((el) => el.getBoundingClientRect().left))
		.toBe(0);
	await expectDrawerClosed(page);
});

test('terminal: the wide text scrolls sideways first; the drawer opens from its left edge', async ({
	page
}) => {
	await fresh(page, threadPath(REMOTE));
	const pre = page.locator('.screen');
	await expect(pre).toBeVisible();
	const left = (): Promise<number> => pre.evaluate((el) => el.scrollLeft);
	expect(await pre.evaluate((el) => el.scrollWidth > el.clientWidth)).toBe(true);

	// Left drag: the text moves, nothing else.
	await drag(page, [300, 300], [200, 300]);
	expect(await left()).toBeGreaterThan(60);
	await expectDrawerClosed(page);

	// Right drag while scrolled: the text moves back, the drawer stays shut.
	await drag(page, [100, 300], [330, 300]);
	await expect.poll(left).toBe(0);
	await expectDrawerClosed(page);

	// Right drag at the left edge: now the drawer opens.
	await drag(page, [60, 300], [300, 300]);
	await expectDrawerOpen(page);
});

test('chat: new messages arrive without a reload', async ({ page }) => {
	await fresh(page, threadPath(LOCAL));
	await expect(page.locator('.a')).toHaveCount(3);
	await page.request.post(`/__fixture/say?id=${LOCAL}&text=The+spec+passes+now.`);
	await expect(page.locator('.a')).toHaveCount(4);
	await expect(page.locator('.a').last()).toHaveText('The spec passes now.');
});

test('a thread the server no longer has says so', async ({ page }) => {
	await fresh(page, threadPath('localhost:999'));
	await expect(page.locator('.empty')).toHaveText('Closed');
});

test('pull down on the chat reloads it', async ({ page }) => {
	await fresh(page, threadPath(LOCAL));
	await expect(page.locator('.u').first()).toBeVisible();
	const cdp = await page.context().newCDPSession(page);
	const touch = (type: string, y?: number): Promise<unknown> =>
		cdp.send('Input.dispatchTouchEvent', {
			type: type as 'touchStart',
			touchPoints: y === undefined ? [] : [{ x: 200, y }]
		});
	let asked = 0;
	page.on('request', (request) => {
		if (request.url().includes('/chat')) asked += 1;
	});
	await touch('touchStart', 300);
	for (const y of [320, 360, 420, 480]) await touch('touchMove', y);
	const pull = page.locator('[data-view="chat"] .pull');
	expect(await pull.evaluate((el) => el.getBoundingClientRect().height)).toBeGreaterThan(56);
	const before = asked;
	await touch('touchEnd');
	await expect.poll(() => asked).toBeGreaterThan(before);
	await expect.poll(() => pull.evaluate((el) => el.getBoundingClientRect().height)).toBe(0);
});
