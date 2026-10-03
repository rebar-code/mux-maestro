import { expect, type Locator, type Page } from '@playwright/test';

export const WIDTH = 390;

export async function reset(page: Page): Promise<void> {
	await page.request.post('/__fixture/reset');
}

/** Open a page with nothing left over from the test before. */
export async function fresh(page: Page, path = '/'): Promise<void> {
	await reset(page);
	await page.goto(path);
	await page.evaluate(() => localStorage.clear());
	await page.goto(path);
}

export const threadPath = (id: string): string => `/t/${encodeURIComponent(id)}`;

export const drawer = (page: Page): Locator => page.locator('[data-drawer]');

/** How far the drawer is from fully open, in pixels (0 = open). */
export async function drawerOffset(page: Page): Promise<number> {
	return drawer(page).evaluate((el) => Math.abs(el.getBoundingClientRect().left));
}

export async function expectDrawerOpen(page: Page): Promise<void> {
	await expect.poll(() => drawerOffset(page)).toBe(0);
}

export async function expectDrawerClosed(page: Page): Promise<void> {
	await expect(drawer(page)).toBeHidden();
}

/** Press, move in steps, and stay down, so a test can look mid-drag. */
export async function dragStart(
	page: Page,
	from: [number, number],
	to: [number, number]
): Promise<void> {
	await page.mouse.move(from[0], from[1]);
	await page.mouse.down();
	await page.mouse.move(to[0], to[1], { steps: 12 });
}

export async function drag(
	page: Page,
	from: [number, number],
	to: [number, number]
): Promise<void> {
	await dragStart(page, from, to);
	// Rest before lifting, so the release is a slow drag and not a flick.
	await page.waitForTimeout(120);
	await page.mouse.up();
}

/** A real touch drag (not a mouse), so the browser applies `touch-action`. */
export async function touchDrag(
	page: Page,
	from: [number, number],
	to: [number, number]
): Promise<void> {
	const cdp = await page.context().newCDPSession(page);
	const send = (
		type: 'touchStart' | 'touchMove' | 'touchEnd',
		point?: [number, number]
	): Promise<unknown> =>
		cdp.send('Input.dispatchTouchEvent', {
			type,
			touchPoints: point ? [{ x: point[0], y: point[1] }] : []
		});
	await send('touchStart', from);
	const steps = 12;
	for (let i = 1; i <= steps; i += 1) {
		await send('touchMove', [
			from[0] + ((to[0] - from[0]) * i) / steps,
			from[1] + ((to[1] - from[1]) * i) / steps
		]);
	}
	await page.waitForTimeout(120);
	await send('touchEnd');
	await cdp.detach();
}
