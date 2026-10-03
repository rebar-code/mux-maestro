import { expect, test, type Page } from '@playwright/test';
import { drag, expectDrawerClosed, fresh, threadPath, touchDrag, twoFingers } from './helpers';

const LOCAL = 'localhost:1';
const REMOTE = 'devbox:2';

const size = (page: Page, selector = 'pre.screen'): Promise<number> =>
	page
		.locator(selector)
		.first()
		.evaluate((el) => parseFloat(getComputedStyle(el).fontSize));

async function terminal(page: Page): Promise<void> {
	await fresh(page, threadPath(REMOTE));
	await expect(page.locator('pre.screen')).toBeVisible();
	expect(await size(page)).toBe(11);
}

test('pinch out makes the terminal text larger, pinch in smaller; the page never zooms', async ({
	page
}) => {
	await terminal(page);
	// Fingers 100px apart move to 160px apart: 11px x 1.6.
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
	expect(await size(page)).toBeCloseTo(17.6, 1);
	expect(await page.evaluate(() => window.visualViewport?.scale)).toBe(1);
	expect(await page.evaluate(() => document.documentElement.clientWidth)).toBe(390);
	await expectDrawerClosed(page);

	// 200px apart to 100px apart: half.
	await twoFingers(
		page,
		[
			[100, 300],
			[300, 300]
		],
		[
			[150, 300],
			[250, 300]
		]
	);
	expect(await size(page)).toBeCloseTo(8.8, 1);
	expect(await page.evaluate(() => window.visualViewport?.scale)).toBe(1);
});

test('the size stops at 24px and at 6px', async ({ page }) => {
	await terminal(page);
	await twoFingers(
		page,
		[
			[180, 300],
			[220, 300]
		],
		[
			[20, 300],
			[380, 300]
		]
	);
	expect(await size(page)).toBe(24);
	await expect(page.getByRole('button', { name: 'Larger text' })).toBeDisabled();
	await twoFingers(
		page,
		[
			[20, 400],
			[380, 400]
		],
		[
			[190, 400],
			[210, 400]
		]
	);
	expect(await size(page)).toBe(6);
	await expect(page.getByRole('button', { name: 'Smaller text' })).toBeDisabled();
});

test('the text under the fingers stays under them, on both axes', async ({ page }) => {
	// This pane has a long scrollback: it scrolls down as well as sideways.
	await fresh(page, threadPath('devbox:5'));
	await expect(page.locator('pre.screen')).toBeVisible();
	await page.locator('[data-view="terminal"]').evaluate((el) => (el.scrollTop = 600));
	const pre = page.locator('pre.screen');
	// A character far along the wide line, scrolled into the middle of the screen.
	const where = (): Promise<{ x: number; y: number }> =>
		pre.evaluate((el) => {
			const node = el.firstChild as Text;
			const at = node.data.indexOf('lines) · Edit');
			const range = document.createRange();
			range.setStart(node, at);
			range.setEnd(node, at + 1);
			const box = range.getBoundingClientRect();
			return { x: box.left, y: (box.top + box.bottom) / 2 };
		});
	await pre.evaluate((el) => (el.scrollLeft = 180));
	const top = await page.locator('[data-view="terminal"]').evaluate((el) => el.scrollTop);
	const before = await where();
	expect(before.x).toBeGreaterThan(40);
	expect(before.x).toBeLessThan(350);

	// Pinch around that character, fingers level with it, and keep them down.
	const { x, y } = before;
	const lift = await twoFingers(
		page,
		[
			[x - 30, y],
			[x + 30, y]
		],
		[
			[x - 55, y],
			[x + 55, y]
		],
		true
	);
	expect(await size(page)).toBeGreaterThan(18);
	const during = await where();
	expect(Math.abs(during.x - x)).toBeLessThan(3);
	expect(Math.abs(during.y - y)).toBeLessThan(3);
	// Both scroll positions moved to hold it there.
	expect(await pre.evaluate((el) => el.scrollLeft)).toBeGreaterThan(250);
	expect(
		await page.locator('[data-view="terminal"]').evaluate((el) => el.scrollTop)
	).toBeGreaterThan(top + 100);
	await lift();
	const after = await where();
	expect(Math.abs(after.x - x)).toBeLessThan(3);
	expect(Math.abs(after.y - y)).toBeLessThan(3);
});

test('a pinch takes over from a drag, and the finger left behind does not start one', async ({
	page
}) => {
	await terminal(page);
	const cdp = await page.context().newCDPSession(page);
	const send = (type: string, points: [number, number][]): Promise<unknown> =>
		cdp.send('Input.dispatchTouchEvent', {
			type: type as 'touchStart',
			touchPoints: points.map(([x, y], id) => ({ x, y, id }))
		});
	const drawerLeft = (): Promise<number> =>
		page.locator('[data-drawer]').evaluate((el) => el.getBoundingClientRect().right);

	// One finger starts opening the drawer.
	await send('touchStart', [[60, 300]]);
	for (const x of [80, 110, 140]) await send('touchMove', [[x, 300]]);
	expect(await drawerLeft()).toBeGreaterThan(30);
	// A second finger lands: the drawer goes back and the pinch begins.
	await send('touchStart', [
		[140, 300],
		[240, 300]
	]);
	await send('touchMove', [
		[120, 300],
		[260, 300]
	]);
	await send('touchMove', [
		[100, 300],
		[280, 300]
	]);
	// 100px apart to 180px apart: 11px x 1.8.
	await expect.poll(() => size(page)).toBeCloseTo(19.8, 1);
	// One finger lifts; the other keeps moving. Nothing follows it.
	const pinched = await size(page);
	// CDP: a touchEnd names the finger that lifts; the other one stays down.
	const raw = (
		type: string,
		touchPoints: { x: number; y: number; id: number }[]
	): Promise<unknown> =>
		cdp.send('Input.dispatchTouchEvent', { type: type as 'touchStart', touchPoints });
	await raw('touchEnd', [{ x: 100, y: 300, id: 0 }]);
	for (const x of [250, 200, 150, 320]) await raw('touchMove', [{ x, y: 300, id: 1 }]);
	await raw('touchEnd', []);
	await page.waitForTimeout(150);
	expect(await size(page)).toBe(pinched);
	await expectDrawerClosed(page);
});

test('A+ and A− change the size by one pixel and stop at the limits', async ({ page }) => {
	await terminal(page);
	const larger = page.getByRole('button', { name: 'Larger text' });
	const smaller = page.getByRole('button', { name: 'Smaller text' });
	for (const button of [larger, smaller]) {
		const box = await button.boundingBox();
		expect(box?.width).toBeGreaterThanOrEqual(44);
		expect(box?.height).toBeGreaterThanOrEqual(44);
	}
	const a = await smaller.boundingBox();
	const b = await larger.boundingBox();
	expect((b?.x ?? 0) - ((a?.x ?? 0) + (a?.width ?? 0))).toBeGreaterThanOrEqual(8);
	// The title keeps a usable width beside them.
	expect((await page.locator('.tbar .title').boundingBox())?.width).toBeGreaterThan(200);

	await larger.click();
	expect(await size(page)).toBe(12);
	await smaller.click();
	await smaller.click();
	expect(await size(page)).toBe(10);

	await page.evaluate(() => localStorage.setItem('mm.textSize', '23'));
	await page.reload();
	await expect(page.locator('pre.screen')).toBeVisible();
	await larger.click();
	expect(await size(page)).toBe(24);
	await expect(larger).toBeDisabled();
	await expect(smaller).toBeEnabled();

	await page.evaluate(() => localStorage.setItem('mm.textSize', '7'));
	await page.reload();
	await expect(page.locator('pre.screen')).toBeVisible();
	await smaller.click();
	expect(await size(page)).toBe(6);
	await expect(smaller).toBeDisabled();
});

test('the size is kept, and the first paint already has it', async ({ page }) => {
	await terminal(page);
	await twoFingers(
		page,
		[
			[150, 300],
			[250, 300]
		],
		[
			[125, 300],
			[275, 300]
		]
	);
	const kept = await size(page);
	expect(kept).toBeCloseTo(16.5, 1);
	expect(await page.evaluate(() => localStorage.getItem('mm.textSize'))).toBe(String(kept));

	// Record the size of the terminal text every time the page changes.
	await page.addInitScript(() => {
		const w = window as unknown as { seen: string[] };
		w.seen = [];
		new MutationObserver(() => {
			const pre = document.querySelector('pre.screen');
			if (pre) w.seen.push(getComputedStyle(pre).fontSize);
		}).observe(document, { childList: true, subtree: true, attributes: true });
	});
	await page.reload();
	await expect(page.locator('pre.screen')).toBeVisible();
	expect(await size(page)).toBe(kept);
	const seen = await page.evaluate(() => (window as unknown as { seen: string[] }).seen);
	expect(seen.length).toBeGreaterThan(0);
	expect([...new Set(seen)]).toEqual([`${kept}px`]);
});

test('a double tap resets the size; one tap and a drag do not', async ({ page }) => {
	await terminal(page);
	await page.getByRole('button', { name: 'Larger text' }).click();
	await page.getByRole('button', { name: 'Larger text' }).click();
	expect(await size(page)).toBe(13);

	await page.touchscreen.tap(200, 500);
	await page.waitForTimeout(500);
	expect(await size(page)).toBe(13);

	// A tap, then a sideways drag: not a double tap.
	await page.touchscreen.tap(200, 500);
	await touchDrag(page, [250, 300], [150, 300]);
	await page.touchscreen.tap(200, 500);
	await page.waitForTimeout(400);
	expect(await size(page)).toBe(13);

	// The first tap of a pinch does not count either.
	await twoFingers(
		page,
		[
			[150, 500],
			[250, 500]
		],
		[
			[150, 500],
			[250, 500]
		]
	);
	await page.touchscreen.tap(200, 500);
	await page.waitForTimeout(400);
	expect(await size(page)).toBe(13);

	await page.touchscreen.tap(200, 500);
	await page.touchscreen.tap(202, 501);
	await expect.poll(() => size(page)).toBe(11);
	expect(await page.evaluate(() => localStorage.getItem('mm.textSize'))).toBe('11');
});

test('a mouse double click resets too, and a drag end does not', async ({ page }) => {
	await terminal(page);
	await page.getByRole('button', { name: 'Larger text' }).click();
	await drag(page, [300, 300], [200, 300]);
	await page.mouse.click(200, 500);
	await page.waitForTimeout(400);
	expect(await size(page)).toBe(12);
	await page.mouse.dblclick(200, 500);
	await expect.poll(() => size(page)).toBe(11);
});

test('chat text follows the size', async ({ page }) => {
	await fresh(page, threadPath(LOCAL));
	await expect(page.locator('.u').first()).toBeVisible();
	expect(await size(page, '.a')).toBe(15);
	expect(await size(page, '.tool')).toBeCloseTo(12.5, 1);
	const larger = page.getByRole('button', { name: 'Larger text' });
	for (let i = 0; i < 5; i += 1) await larger.click();
	// 16px terminal text: chat is 15 x 16 / 11.
	expect(await size(page, '.a')).toBeCloseTo(21.82, 1);
	expect(await size(page, '.u')).toBeCloseTo(21.82, 1);
	expect(await size(page, '.tool')).toBeCloseTo(18.18, 1);
	// The same size shows in the terminal.
	await page.locator('[data-tab="main"]').click();
	expect(await size(page)).toBe(16);
});

test('reduced motion: a size change is not animated', async ({ page }) => {
	await page.emulateMedia({ reducedMotion: 'reduce' });
	await terminal(page);
	const duration = await page
		.locator('pre.screen')
		.evaluate((el) => getComputedStyle(el).transitionDuration);
	expect(duration).toMatch(/^0s/);
});
