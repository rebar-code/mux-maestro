import { expect, test, type Page } from '@playwright/test';
import { drag, expectDrawerClosed, fresh, threadPath, touchDrag, twoFingers } from './helpers';

const LOCAL = 'localhost:1';
const REMOTE = 'devbox:2';
const MAKER = 'localhost:6';

const size = (page: Page, selector = '.screen'): Promise<number> =>
	page
		.locator(selector)
		.first()
		.evaluate((el) => parseFloat(getComputedStyle(el).fontSize));

async function terminal(page: Page): Promise<void> {
	await fresh(page, threadPath(REMOTE));
	await expect(page.locator('.screen')).toBeVisible();
	expect(await size(page)).toBe(11);
}

/** Start from a size an earlier pinch stored on this phone. */
async function stored(page: Page, px: number, selector = '.screen'): Promise<void> {
	await page.evaluate((value) => localStorage.setItem('mm.textSize', String(value)), px);
	await page.reload();
	await expect(page.locator(selector).first()).toBeVisible();
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
});

test('the text under the fingers stays under them, on both axes', async ({ page }) => {
	// This pane has a long scrollback: it scrolls down as well as sideways.
	await fresh(page, threadPath('devbox:5'));
	await expect(page.locator('.screen')).toBeVisible();
	// Far enough down that the wide line is clear of the reply box at the bottom.
	await page.locator('[data-view="terminal"]').evaluate((el) => (el.scrollTop = 690));
	const pre = page.locator('.screen');
	// A character far along the wide line, scrolled into the middle of the screen.
	const where = (): Promise<{ x: number; y: number }> =>
		pre.evaluate((el) => {
			const needle = 'lines) · Edit';
			const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
			let node = walker.nextNode() as Text | null;
			while (node && !node.data.includes(needle)) node = walker.nextNode() as Text | null;
			if (!node) throw new Error('text not found');
			const at = node.data.indexOf(needle);
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

test('there are no text size buttons; pinch and double tap are the controls', async ({ page }) => {
	await terminal(page);
	await expect(page.getByRole('button', { name: /text/i })).toHaveCount(0);
	await expect(page.getByText(/^A[−+-]$/)).toHaveCount(0);
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
			const pre = document.querySelector('.screen');
			if (pre) w.seen.push(getComputedStyle(pre).fontSize);
		}).observe(document, { childList: true, subtree: true, attributes: true });
	});
	await page.reload();
	await expect(page.locator('.screen')).toBeVisible();
	expect(await size(page)).toBe(kept);
	const seen = await page.evaluate(() => (window as unknown as { seen: string[] }).seen);
	expect(seen.length).toBeGreaterThan(0);
	expect([...new Set(seen)]).toEqual([`${kept}px`]);
});

test('a double tap resets the size; one tap and a drag do not', async ({ page }) => {
	await terminal(page);
	await stored(page, 13);
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
	await stored(page, 12);
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
	await stored(page, 16, '.u');
	// 16px terminal text: chat is 15 x 16 / 11.
	expect(await size(page, '.a')).toBeCloseTo(21.82, 1);
	expect(await size(page, '.u')).toBeCloseTo(21.82, 1);
	expect(await size(page, '.tool')).toBeCloseTo(18.18, 1);
	// The same size shows in the terminal.
	await page.locator('[data-tab="main"]').click();
	expect(await size(page)).toBe(16);
});

/** Screenshots are taken only when SHOTS names a directory outside the repo. */
async function shot(page: Page, name: string): Promise<void> {
	const dir = process.env.SHOTS;
	if (!dir) return;
	await page.waitForTimeout(300);
	await page.screenshot({ path: `${dir}/${name}.png` });
}

async function chat(page: Page, id = LOCAL): Promise<void> {
	await fresh(page, threadPath(id));
	await expect(page.locator('[data-view="chat"] .u').first()).toBeVisible();
	expect(await size(page, '.a')).toBe(15);
}

test('a pinch on the chat changes the text size as on the terminal; the page never zooms', async ({
	page
}) => {
	await chat(page);
	await shot(page, 'chat-before');
	// Fingers 100px apart move to 160px apart: 15px x 1.6.
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
	expect(await size(page, '.a')).toBeCloseTo(24, 1);
	expect(await size(page, '.u')).toBeCloseTo(24, 1);
	await shot(page, 'chat-pinched-out');
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
	expect(await size(page, '.a')).toBeCloseTo(12, 1);
	expect(await page.evaluate(() => window.visualViewport?.scale)).toBe(1);

	// The size is kept, and the terminal has it too.
	await page.reload();
	await expect(page.locator('[data-view="chat"] .u').first()).toBeVisible();
	expect(await size(page, '.a')).toBeCloseTo(12, 1);
	await page.locator('[data-tab="main"]').click();
	expect(await size(page)).toBeCloseTo(8.8, 1);
});

test('the chat message under the fingers stays under them', async ({ page }) => {
	// A long thread of paragraphs that wrap, read from the middle.
	await fresh(page, '/');
	const paragraph = 'The export reads every row before it writes the first one. '.repeat(6);
	for (let n = 1; n <= 12; n += 1) {
		await page.request.post(
			`/__fixture/say?id=${MAKER}&role=assistant&text=${encodeURIComponent(`Step ${n}. ${paragraph}`)}`
		);
	}
	await page.goto(threadPath(MAKER));
	await expect(page.locator('[data-view="chat"] .u').first()).toBeVisible();
	const scroller = page.locator('[data-view="chat"]');
	await scroller.evaluate((el) => (el.scrollTop = Math.round(el.scrollTop / 2)));
	expect(await scroller.evaluate((el) => el.scrollTop)).toBeGreaterThan(600);
	const MID: [number, number] = [200, 400];
	/** How far the point the fingers began on is from them now, in pixels. */
	const drift = await page.evaluateHandle(([x, y]) => {
		const held = document.elementFromPoint(x, y)!;
		const box = held.getBoundingClientRect();
		const at = (y - box.top) / box.height;
		return () => {
			const now = held.getBoundingClientRect();
			return now.top + now.height * at - y;
		};
	}, MID);
	const lift = await twoFingers(
		page,
		[
			[150, 400],
			[250, 400]
		],
		[
			[110, 400],
			[290, 400]
		],
		true
	);
	expect(await size(page, '.a')).toBeCloseTo(27, 1);
	// Within a line of the larger text.
	expect(Math.abs(await drift.evaluate((measure) => measure()))).toBeLessThan(30);
	await lift();
	expect(Math.abs(await drift.evaluate((measure) => measure()))).toBeLessThan(30);
});

test('a double tap on the chat resets the size', async ({ page }) => {
	await chat(page);
	await stored(page, 16, '.u');
	expect(await size(page, '.a')).toBeCloseTo(21.82, 1);
	const box = (await page.locator('[data-view="chat"] .u').first().boundingBox())!;
	const at: [number, number] = [box.x + box.width / 2, box.y + box.height / 2];
	await page.touchscreen.tap(...at);
	await page.waitForTimeout(500);
	expect(await size(page, '.a')).toBeCloseTo(21.82, 1);
	// Two taps on an agent's message are its menu: the size stays.
	const agent = (await page.locator('[data-view="chat"] .a').first().boundingBox())!;
	await page.touchscreen.tap(agent.x + 24, agent.y + 12);
	await page.touchscreen.tap(agent.x + 24, agent.y + 12);
	await expect(page.locator('[data-menu]')).toHaveCount(1);
	expect(await size(page, '.a')).toBeCloseTo(21.82, 1);
	await page.waitForTimeout(500);
	await page.touchscreen.tap(...at);
	await page.touchscreen.tap(...at);
	await expect.poll(() => size(page, '.a')).toBe(15);
});

test('a pinch at the end of the home thread changes the text size and does not leave the chat', async ({
	page
}) => {
	await fresh(page);
	const thread = page.locator('[data-view="chat"]');
	await expect(thread.locator('.a').first()).toBeVisible();
	// The board is a tab beside the chat: the chat's own tab stays the one shown.
	const tab = page.getByRole('tab').first();
	await expect(tab).toHaveAttribute('aria-selected', 'true');
	const before = await size(page, '.a');
	// One finger goes up by more than a swipe; the other goes down.
	const box = (await thread.boundingBox())!;
	const x = box.x + box.width / 2;
	const y = box.y + box.height / 2;
	const lift = await twoFingers(
		page,
		[
			[x, y - 20],
			[x, y + 20]
		],
		[
			[x, y - 120],
			[x, y + 120]
		],
		true
	);
	expect(await size(page, '.a')).toBeGreaterThan(before);
	await lift();
	await page.waitForTimeout(300);
	await expect(tab).toHaveAttribute('aria-selected', 'true');
});

test('reduced motion: a size change is not animated', async ({ page }) => {
	await page.emulateMedia({ reducedMotion: 'reduce' });
	await terminal(page);
	const duration = await page
		.locator('.screen')
		.evaluate((el) => getComputedStyle(el).transitionDuration);
	expect(duration).toMatch(/^0s/);
});
