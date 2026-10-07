import { expect, test, type Locator, type Page } from '@playwright/test';
import {
	drag,
	drawer,
	expectDrawerClosed,
	expectDrawerOpen,
	fresh,
	threadPath,
	touchDrag
} from './helpers';

const ROW = 'localhost:3';
/** Two buttons of 56px. */
const PULLED = 112;

const row = (page: Page, id = ROW): Locator => drawer(page).locator(`[data-thread="${id}"]`);
const filterButton = (page: Page): Locator =>
	page.getByRole('button', { name: 'Filter', exact: true });
/** Asleep, and written 90 minutes ago. */
const RECENT = 'localhost:200';
const left = (target: Locator): Promise<number> =>
	target.evaluate((el) => Math.round(el.getBoundingClientRect().left));

/** Screenshots are taken only when SHOTS names a directory outside the repo. */
async function shot(page: Page, name: string): Promise<void> {
	const dir = process.env.SHOTS;
	if (!dir) return;
	await page.waitForTimeout(300);
	await page.screenshot({ path: `${dir}/${name}.png` });
}

async function actions(page: Page): Promise<Record<string, unknown>[]> {
	const sent = await (await page.request.post('/__fixture/replies')).json();
	return sent.actions as Record<string, unknown>[];
}

/** Swipe the row sideways by `dx`, with a finger. */
async function swipe(page: Page, target: Locator, dx: number): Promise<void> {
	await target.scrollIntoViewIfNeeded();
	const box = await target.boundingBox();
	if (!box) throw new Error('nothing to swipe');
	const y = box.y + box.height / 2;
	const x = dx > 0 ? box.x + 60 : box.x + box.width - 40;
	await touchDrag(page, [x, y], [x + dx, y + 3]);
}

// The kill switch stays off: none of this needs it.
test.beforeEach(async ({ page }) => {
	await fresh(page);
	await page.request.post('/__fixture/capability?name=sessionActions&on=1');
	await page.getByRole('button', { name: 'Menu' }).click();
	await expectDrawerOpen(page);
});

test('a right swipe on a row shows its menu and archive buttons', async ({ page }) => {
	const rest = await left(row(page));
	await swipe(page, row(page), 150);
	await expect.poll(() => left(row(page))).toBe(rest + PULLED);
	await expectDrawerOpen(page);
	await expect(page).toHaveURL(/\/$/);

	const buttons = row(page).locator('..').getByRole('button');
	await expect(buttons).toHaveCount(2);
	// The menu is the left one, archive the right one, and both are touch targets.
	const [menu, archive] = [await buttons.nth(0).boundingBox(), await buttons.nth(1).boundingBox()];
	await expect(buttons.nth(0)).toHaveAccessibleName('Menu for search');
	await expect(buttons.nth(1)).toHaveAccessibleName('Archive search');
	expect(menu?.x ?? 0).toBeLessThan(archive?.x ?? 0);
	for (const box of [menu, archive]) {
		expect(box?.width ?? 0).toBeGreaterThanOrEqual(44);
		expect(box?.height ?? 0).toBeGreaterThanOrEqual(44);
	}
	await shot(page, 'row-swiped');
});

test('a short slow swipe springs back', async ({ page }) => {
	const rest = await left(row(page));
	const box = await row(page).boundingBox();
	if (!box) throw new Error('no row');
	await drag(page, [box.x + 60, box.y + 20], [box.x + 95, box.y + 20]);
	await expect.poll(() => left(row(page))).toBe(rest);
});

test('the menu button opens the menu a long press opens', async ({ page }) => {
	await swipe(page, row(page), 150);
	await page.getByRole('button', { name: 'Menu for search', exact: true }).click();
	const sheet = page.getByRole('dialog');
	await expect(sheet.locator('.title')).toHaveText('docs-site · search');
	await expect(sheet.getByRole('button')).toHaveText([
		'New Window…',
		'Rename Window…',
		'Archive Window',
		'Zoom Pane'
	]);
	await shot(page, 'row-menu');
});

test('archive goes at once, with nothing to confirm', async ({ page }) => {
	await swipe(page, row(page), 150);
	await page.getByRole('button', { name: 'Archive search', exact: true }).click();
	await expect(row(page)).toHaveCount(0);
	await expect(page.getByRole('dialog')).toHaveCount(0);
	expect(await actions(page)).toEqual([{ action: 'archive-window', thread: ROW }]);
	await expectDrawerOpen(page);
});

test('archiving the open thread leaves it', async ({ page }) => {
	await page.goto(threadPath(ROW));
	await page.getByRole('button', { name: 'Menu' }).click();
	await expectDrawerOpen(page);
	await swipe(page, row(page), 150);
	await page.getByRole('button', { name: 'Archive search', exact: true }).click();
	await expect(page).toHaveURL(/\/$/);
});

test('a left swipe puts the row back, and the next one closes the drawer', async ({ page }) => {
	const rest = await left(row(page));
	await swipe(page, row(page), 150);
	await expect.poll(() => left(row(page))).toBe(rest + PULLED);
	await swipe(page, row(page), -150);
	await expect.poll(() => left(row(page))).toBe(rest);
	await expectDrawerOpen(page);
	await swipe(page, row(page), -200);
	await expectDrawerClosed(page);
});

test('a tap on a pulled row puts it back and does not open it', async ({ page }) => {
	const rest = await left(row(page));
	await swipe(page, row(page), 150);
	await expect.poll(() => left(row(page))).toBe(rest + PULLED);
	await row(page).click({ position: { x: 150, y: 10 } });
	await expect.poll(() => left(row(page))).toBe(rest);
	await expect(page).toHaveURL(/\/$/);
	await expectDrawerOpen(page);
});

test('a touch on another row puts the pulled one back', async ({ page }) => {
	const rest = await left(row(page));
	await swipe(page, row(page), 150);
	await swipe(page, row(page, 'localhost:1'), 150);
	await expect.poll(() => left(row(page))).toBe(rest);
	await expect.poll(() => left(row(page, 'localhost:1'))).toBe(rest + PULLED);
});

test('a row has no buttons while session actions are off', async ({ page }) => {
	await page.request.post('/__fixture/capability?name=sessionActions&on=0');
	await page.reload();
	await page.getByRole('button', { name: 'Menu' }).click();
	await expectDrawerOpen(page);
	const rest = await left(row(page));
	await swipe(page, row(page), 150);
	expect(await left(row(page))).toBe(rest);
	await expect(row(page).locator('..').getByRole('button')).toHaveCount(0);
});

test('a row shows the pull request of its window', async ({ page }) => {
	await expect(row(page, 'localhost:1').locator('.pr')).toHaveText('#128');
	await expect(row(page).locator('.pr')).toHaveCount(0);
});

test('the filter opens every session and shows the list from its top', async ({ page }) => {
	const filter = filterButton(page);
	const folds = drawer(page).locator('.shead .fold');
	const scroll = drawer(page).locator('.scroll');
	await folds.first().click();
	await expect(folds.first()).toHaveAttribute('aria-expanded', 'false');
	// Down at the hosts, where the threads are out of view.
	await scroll.evaluate((el) => el.scrollTo({ top: el.scrollHeight }));
	expect(await scroll.evaluate((el) => el.scrollTop)).toBeGreaterThan(0);

	await filter.click();
	await expect(filter).toHaveAttribute('aria-pressed', 'true');
	await expect(drawer(page).locator('.fold[aria-expanded="false"]')).toHaveCount(0);
	await expect.poll(() => scroll.evaluate((el) => el.scrollTop)).toBe(0);

	// Off again: also from the top.
	await scroll.evaluate((el) => el.scrollTo({ top: el.scrollHeight }));
	await filter.click();
	await expect.poll(() => scroll.evaluate((el) => el.scrollTop)).toBe(0);
});

test('the filter beside Maestro leaves the sleeping threads out', async ({ page }) => {
	const filter = filterButton(page);
	const maestro = drawer(page).locator('[data-home]');
	expect((await filter.boundingBox())?.x ?? 0).toBeLessThan((await maestro.boundingBox())?.x ?? 0);
	expect((await filter.boundingBox())?.width ?? 0).toBeGreaterThanOrEqual(44);
	const all = await drawer(page).locator('[data-thread]').count();
	await expect(drawer(page).locator('[data-thread].sleep').first()).toBeAttached();

	await filter.click();
	await expect(filter).toHaveAttribute('aria-pressed', 'true');
	await expect(drawer(page).locator('[data-thread].sleep')).toHaveCount(0);
	expect(await drawer(page).locator('[data-thread]').count()).toBeLessThan(all);
	await expect(row(page)).toBeAttached();
	await shot(page, 'filter-on');

	// The phone keeps it.
	await page.reload();
	await page.getByRole('button', { name: 'Menu' }).click();
	await expect(filterButton(page)).toHaveAttribute('aria-pressed', 'true');
	await expect(filterButton(page)).toHaveText('Sleepy');
	await filterButton(page).click();
	await expect(drawer(page).locator('[data-thread]')).toHaveCount(all);
});

test('the arrow beside the filter keeps the sleeping threads of the last 2 hours', async ({
	page
}) => {
	const filter = filterButton(page);
	const all = await drawer(page).locator('[data-thread]').count();
	await filter.click();
	await expect(row(page, RECENT)).toHaveCount(0);
	const awake = await drawer(page).locator('[data-thread]').count();

	await page.getByRole('button', { name: 'Filter options' }).click();
	const options = page.getByRole('menuitemradio');
	await expect(options).toHaveText(['Sleepy', '2 hours', 'Today']);
	await expect(options.nth(0)).toHaveAttribute('aria-checked', 'true');
	await shot(page, 'filter-menu');
	await options.nth(1).click();
	await expect(page.getByRole('menu')).toHaveCount(0);
	await expect(filter).toHaveText('2 hours');
	await expect(row(page, RECENT)).toBeAttached();
	await expect(drawer(page).locator('[data-thread]')).toHaveCount(awake + 1);
	await shot(page, 'filter-2h');

	// The phone keeps the mode.
	await page.reload();
	await page.getByRole('button', { name: 'Menu' }).click();
	await expect(filterButton(page)).toHaveText('2 hours');

	// One tap turns any mode off; the next one is Sleepy again.
	await filterButton(page).click();
	await expect(filterButton(page)).toHaveAttribute('aria-pressed', 'false');
	await expect(drawer(page).locator('[data-thread]')).toHaveCount(all);
	await filterButton(page).click();
	await expect(filterButton(page)).toHaveText('Sleepy');
});

test('a tap outside the filter options closes them and changes nothing', async ({ page }) => {
	await page.getByRole('button', { name: 'Filter options' }).click();
	await expect(page.getByRole('menu')).toBeVisible();
	await drawer(page)
		.getByRole('button', { name: 'Close' })
		.click({ position: { x: 150, y: 200 } });
	await expect(page.getByRole('menu')).toHaveCount(0);
	await expect(filterButton(page)).toHaveAttribute('aria-pressed', 'false');
});

test('a phone that kept the old switch on opens with Sleepy', async ({ page }) => {
	await page.evaluate(() => localStorage.setItem('mm.awake', 'true'));
	await page.reload();
	await page.getByRole('button', { name: 'Menu' }).click();
	await expect(filterButton(page)).toHaveText('Sleepy');
});

test('the Maestro row shows the dot of what its pane does', async ({ page }) => {
	const home = drawer(page).locator('[data-home]');
	const dot = home.locator('.dot');
	await expect(home).toHaveAttribute('data-state', 'idle');
	await expect(dot).toHaveClass(/idle/);

	for (const [query, state, cls] of [
		['value=busy', 'running', /busy/],
		['value=waiting', 'needs you', /waiting/],
		['value=idle&stage=dozing', 'sleeping', /idle/]
	] as const) {
		await page.request.post(`/__fixture/manager-status?${query}`);
		await page.reload();
		await page.getByRole('button', { name: 'Menu' }).click();
		await expect(home).toHaveAttribute('data-state', state);
		await expect(dot).toHaveClass(cls);
		await shot(page, `maestro-${state.replace(' ', '-')}`);
	}
	await expect(home).toContainText('💤');

	// Switched off on the Mac: no dot.
	await page.request.post('/__fixture/capability?name=manager&on=0');
	await page.reload();
	await page.getByRole('button', { name: 'Menu' }).click();
	await expect(dot).toHaveCount(0);
});
