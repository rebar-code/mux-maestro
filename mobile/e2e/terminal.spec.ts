import { expect, test, type Locator, type Page } from '@playwright/test';
import { fresh, threadPath } from './helpers';

// A remote pane (terminal only) with 500 numbered, coloured lines.
const LOG = 'buildbox:8';

const scroller = (page: Page): Locator => page.locator('[data-view="terminal"]');
const line = (page: Page, n: number): Locator =>
	page.locator('.ln', { hasText: `line ${String(n).padStart(3, '0')}` });
const y = async (target: Locator): Promise<number> =>
	target.evaluate((el) => el.getBoundingClientRect().top);
const label = (page: Page, n: number): Locator => line(page, n).locator('span').first();
const color = (target: Locator): Promise<string> =>
	target.evaluate((el) => getComputedStyle(el).color);
const jump = (page: Page): Locator => page.getByRole('button', { name: 'Jump to bottom' });
const older = (page: Page): Locator => page.getByRole('button', { name: 'Load older' });

async function open(page: Page, setup?: () => Promise<unknown>): Promise<void> {
	await fresh(page, '/');
	await setup?.();
	await page.goto(threadPath(LOG));
	await expect(line(page, 500)).toBeAttached();
}

test('opens at the bottom, with all the scrollback above', async ({ page }) => {
	await open(page);
	await expect(line(page, 500)).toBeInViewport();
	await expect(line(page, 1)).toBeAttached();
	await expect(page.locator('.ln')).toHaveCount(500);
	await expect(jump(page)).toHaveCount(0);
	// All 500 fit in what was asked for, so there is nothing older to load.
	await expect(older(page)).toHaveCount(0);
	// One element per line: nothing wraps.
	const heights = await page
		.locator('.ln')
		.evaluateAll((els) => [
			...new Set(els.slice(-20).map((el) => el.getBoundingClientRect().height))
		]);
	expect(heights).toHaveLength(1);
});

test('colours and attributes are drawn', async ({ page }) => {
	await open(page);
	// 31 + n % 6: line 499 is 32 (green), line 500 is 33 (yellow).
	expect(await color(label(page, 499))).toBe('rgb(69, 212, 131)');
	expect(await color(label(page, 500))).toBe('rgb(227, 179, 65)');
	// After the reset the rest of the line has the default colour.
	expect(await color(line(page, 500).locator('span').nth(1))).toBe('rgb(207, 207, 207)');
	// 256-colour and truecolor.
	expect(await color(label(page, 100))).toBe('rgb(255, 135, 0)');
	expect(await color(label(page, 200))).toBe('rgb(255, 100, 0)');
	// Bold and inverse: the colours swap; then a dim run.
	const inverse = label(page, 450);
	expect(await color(inverse)).toBe('rgb(10, 10, 10)');
	expect(await inverse.evaluate((el) => getComputedStyle(el).backgroundColor)).toBe(
		'rgb(207, 207, 207)'
	);
	expect(await inverse.evaluate((el) => getComputedStyle(el).fontWeight)).toBe('700');
	expect(
		await line(page, 450)
			.locator('span')
			.nth(1)
			.evaluate((el) => getComputedStyle(el).opacity)
	).toBe('0.6');
	// A background, then italic and underline.
	expect(await label(page, 460).evaluate((el) => getComputedStyle(el).backgroundColor)).toBe(
		'rgb(50, 145, 255)'
	);
	const styled = line(page, 460).locator('span', { hasText: 'italic underline' });
	expect(await styled.evaluate((el) => getComputedStyle(el).fontStyle)).toBe('italic');
	expect(await styled.evaluate((el) => getComputedStyle(el).textDecorationLine)).toBe('underline');
});

test('pane text is never markup, and other escape sequences vanish', async ({ page }) => {
	let alerted = false;
	page.on('dialog', (dialog) => {
		alerted = true;
		void dialog.dismiss();
	});
	await open(page);
	await expect(line(page, 300)).toHaveText('line 300  <script>alert(1)</script>');
	expect(await page.locator('.screen script').count()).toBe(0);
	expect(await page.locator('.screen *:not(div):not(span)').count()).toBe(0);
	// The window title and the erase sequence are gone; the text around them stays.
	await expect(line(page, 400)).toHaveText('line 400  after a title');
	await expect(page.locator('.screen')).not.toContainText('window title');
	await expect(page.locator('.screen')).not.toContainText('[0m');
	expect(alerted).toBe(false);
});

test('scrolled up: new output leaves the view where it is, and a button jumps back', async ({
	page
}) => {
	await open(page);
	await scroller(page).evaluate((el) => (el.scrollTop = el.scrollHeight / 2));
	await expect(jump(page)).toBeVisible();
	const box = await jump(page).boundingBox();
	expect(box?.width).toBeGreaterThanOrEqual(44);
	expect(box?.height).toBeGreaterThanOrEqual(44);

	const seen = line(page, 255);
	await expect(seen).toBeInViewport();
	const before = await y(seen);
	const top = await scroller(page).evaluate((el) => el.scrollTop);
	await page.request.post('/__fixture/append?count=20');
	await expect(line(page, 520)).toBeAttached();
	expect(Math.abs((await y(seen)) - before)).toBeLessThanOrEqual(2);
	expect(await scroller(page).evaluate((el) => el.scrollTop)).toBe(top);
	await expect(line(page, 520)).not.toBeInViewport();
	await expect(jump(page)).toBeVisible();

	await jump(page).click();
	await expect(line(page, 520)).toBeInViewport();
	await expect(jump(page)).toHaveCount(0);

	// Back at the bottom, it follows again.
	await page.request.post('/__fixture/append?count=5');
	await expect(line(page, 525)).toBeInViewport();
	await expect(jump(page)).toHaveCount(0);
});

test('a full window: output pushes lines off the top and the view still holds', async ({
	page
}) => {
	// The server sends 100 lines at most by default here, so new lines displace old ones.
	await open(page, () => page.request.post('/__fixture/screen?default=100&max=100'));
	await expect(page.locator('.ln')).toHaveCount(100);
	await expect(line(page, 400)).toHaveCount(0);
	await scroller(page).evaluate((el) => (el.scrollTop = 200));
	await expect(jump(page)).toBeVisible();
	const seen = line(page, 430);
	await expect(seen).toBeInViewport();
	const before = await y(seen);
	await page.request.post('/__fixture/append?count=10');
	await expect(line(page, 510)).toBeAttached();
	await expect(line(page, 405)).toHaveCount(0);
	await expect(page.locator('.ln')).toHaveCount(100);
	expect(Math.abs((await y(seen)) - before)).toBeLessThanOrEqual(2);
});

test('"Load older" adds lines above without moving the view, and goes away at the limit', async ({
	page
}) => {
	await open(page, () => page.request.post('/__fixture/screen?default=100&max=400'));
	await expect(page.locator('.ln')).toHaveCount(100);
	await expect(line(page, 401)).toBeAttached();
	await expect(line(page, 400)).toHaveCount(0);

	await scroller(page).evaluate((el) => (el.scrollTop = 0));
	await expect(older(page)).toBeVisible();
	expect((await older(page).boundingBox())?.height).toBeGreaterThanOrEqual(44);
	const asked: string[] = [];
	page.on('request', (request) => {
		if (request.url().includes('/screen?lines=')) asked.push(new URL(request.url()).search);
	});

	const first = line(page, 401);
	const before = await y(first);
	await older(page).click();
	await expect(line(page, 301)).toBeAttached();
	await expect(page.locator('.ln')).toHaveCount(200);
	expect(Math.abs((await y(first)) - before)).toBeLessThanOrEqual(2);
	expect(asked).toContain('?lines=200');

	// Twice as many again reaches the limit of 400: the control is gone.
	await scroller(page).evaluate((el) => (el.scrollTop = 0));
	const second = line(page, 301);
	const beforeSecond = await y(second);
	await older(page).click();
	await expect(line(page, 101)).toBeAttached();
	await expect(page.locator('.ln')).toHaveCount(400);
	await expect(older(page)).toHaveCount(0);
	// The control took up room above the lines; the view still holds.
	expect(Math.abs((await y(second)) - beforeSecond)).toBeLessThanOrEqual(2);
	expect(asked).toContain('?lines=400');
});

test('unchanged text: the refetch names its tag, gets 304, and nothing is drawn again', async ({
	page
}) => {
	await open(page);
	// Mark nodes: a redraw that replaced them would lose the marks.
	await page
		.locator('.ln')
		.evaluateAll((els) => els.forEach((el) => el.setAttribute('data-mark', '1')));
	const changes = await page.evaluateHandle(() => {
		const seen = { count: 0 };
		new MutationObserver((records) => (seen.count += records.length)).observe(
			document.querySelector('.screen') as Element,
			{ childList: true, subtree: true, characterData: true }
		);
		return seen;
	});
	const response = await page.waitForResponse(
		(r) => r.url().includes('/screen') && r.status() === 304
	);
	expect(response.request().headers()['if-none-match']).toMatch(/^"[0-9a-f]+"$/);
	expect(response.request().headers()['x-muxmaestro-token']).toBe('demo-token');
	await page.waitForTimeout(200);
	expect(await page.locator('.ln[data-mark]').count()).toBe(500);
	expect(await changes.evaluate((seen) => seen.count)).toBe(0);

	// And a real change keeps the lines it already drew.
	await page.request.post('/__fixture/append?count=3');
	await expect(line(page, 503)).toBeAttached();
	expect(await page.locator('.ln[data-mark]').count()).toBe(500);
});

test('the text size applies to the coloured lines', async ({ page }) => {
	await open(page);
	const size = (): Promise<string> =>
		label(page, 500).evaluate((el) => getComputedStyle(el).fontSize);
	expect(await size()).toBe('11px');
	// The size a pinch stored on this phone.
	await page.evaluate(() => localStorage.setItem('mm.textSize', '13'));
	await page.reload();
	await expect(line(page, 500)).toBeAttached();
	expect(await size()).toBe('13px');
	// Lines grow with it and still do not wrap.
	expect(await line(page, 500).evaluate((el) => el.getBoundingClientRect().height)).toBe(17);
	await expect(page.locator('.ln')).toHaveCount(500);
});

test('wide lines scroll sideways; nothing reflows', async ({ page }) => {
	await open(page);
	const screen = page.locator('.screen');
	expect(await screen.evaluate((el) => el.scrollWidth > el.clientWidth + 100)).toBe(true);
	expect(await label(page, 500).evaluate((el) => getComputedStyle(el).whiteSpace)).toBe('pre');
	// The width does not depend on which lines are on screen.
	const width = await screen.evaluate((el) => el.scrollWidth);
	await scroller(page).evaluate((el) => (el.scrollTop = 0));
	expect(await screen.evaluate((el) => el.scrollWidth)).toBe(width);
});
