import { expect, test, type Locator, type Page } from '@playwright/test';
import { drawer, expectDrawerOpen, fresh, threadPath } from './helpers';

const ACME = 'localhost/acme-app';
const WAITING = 'localhost:1'; // acme-app · checkout-fix, needs you

const head = (page: Page, key = ACME): Locator => drawer(page).locator(`[data-session="${key}"]`);
const fold = (page: Page, key = ACME): Locator => head(page, key).locator('.fold');
/** The session's windows: the element its header button controls. */
const windows = (page: Page, key = ACME): Locator =>
	drawer(page).locator(`[data-session="${key}"] + .windows`);
const rows = (page: Page, key = ACME): Locator => windows(page, key).locator('[data-thread]');

async function openDrawer(page: Page): Promise<void> {
	await page.getByRole('button', { name: 'Menu' }).click();
	await expectDrawerOpen(page);
}

test.beforeEach(async ({ page }) => {
	await fresh(page);
	await openDrawer(page);
});

test('a tap on the session header collapses its windows, and a second tap expands them', async ({
	page
}) => {
	const count = await rows(page).count();
	expect(count).toBeGreaterThan(1);
	await expect(rows(page).first()).toBeVisible();
	await expect(fold(page)).toHaveAttribute('aria-expanded', 'true');

	await fold(page).click();
	await expect(fold(page)).toHaveAttribute('aria-expanded', 'false');
	await expect(rows(page).first()).toBeHidden();
	// The rows take no room: the next header sits right under this one.
	await expect.poll(async () => (await windows(page).boundingBox())?.height ?? -1).toBe(0);
	const next = drawer(page).locator('.shead').nth(1);
	const below = async (): Promise<number> =>
		((await next.boundingBox())?.y ?? 0) -
		((await head(page).boundingBox())?.y ?? 0) -
		((await head(page).boundingBox())?.height ?? 0);
	expect(await below()).toBeLessThan(2);

	await fold(page).click();
	await expect(fold(page)).toHaveAttribute('aria-expanded', 'true');
	await expect(rows(page).first()).toBeVisible();
	await expect(rows(page)).toHaveCount(count);
});

test('a collapsed session keeps its name, host colour, window count and strongest status', async ({
	page
}) => {
	const count = await rows(page).count();
	await fold(page).click();
	await expect(head(page).locator('b')).toHaveText('acme-app');
	await expect(head(page).locator('.cnt')).toHaveText(String(count));
	// The host chip keeps the host's colour.
	const chip = head(page).locator('.host');
	await expect(chip).toHaveText('localhost');
	expect(await chip.evaluate((el) => getComputedStyle(el).color)).toBe('rgb(50, 145, 255)');
	// One thread in it needs the user: that wins over the running and idle ones.
	await expect(head(page).locator('[data-summary]')).toHaveAttribute('data-summary', 'waiting');
	expect(
		await head(page)
			.locator('[data-summary]')
			.evaluate((el) => getComputedStyle(el).backgroundColor)
	).toBe('rgb(248, 81, 73)');
	// A screen reader hears it: the dot carries text, and so does the button's name.
	await expect(head(page).locator('[data-summary] .sr')).toHaveText('needs you');
	await expect(fold(page)).toHaveAccessibleName(/acme-app.*needs you/);
	const sr = await head(page).locator('[data-summary] .sr').boundingBox();
	expect(sr?.width).toBeLessThanOrEqual(1);
	// An open session shows no summary: its rows carry their own dots.
	await fold(page).click();
	await expect(head(page).locator('[data-summary]')).toHaveCount(0);
});

test('a thread that starts to need you shows on its collapsed session', async ({ page }) => {
	const key = 'localhost/docs-site';
	await fold(page, key).click();
	await expect(head(page, key).locator('[data-summary]')).toHaveAttribute('data-summary', 'busy');
	const id = await rows(page, key).first().getAttribute('data-thread');
	await page.request.post(`/__fixture/wait?id=${encodeURIComponent(id ?? '')}`);
	await expect(head(page, key).locator('[data-summary]')).toHaveAttribute(
		'data-summary',
		'waiting'
	);
});

test('the keyboard toggles the session, and its windows leave the tab order', async ({ page }) => {
	await fold(page).focus();
	await page.keyboard.press('Enter');
	await expect(fold(page)).toHaveAttribute('aria-expanded', 'false');
	await expect(windows(page)).toHaveAttribute('inert', '');
	// Tab goes from the header past the hidden rows: focus never lands in them.
	await page.keyboard.press('Tab');
	await page.keyboard.press('Tab');
	expect(await windows(page).evaluate((el) => el.contains(document.activeElement))).toBe(false);

	await fold(page).focus();
	await page.keyboard.press('Space');
	await expect(fold(page)).toHaveAttribute('aria-expanded', 'true');
	await expect(rows(page).first()).toBeVisible();
});

test('aria-controls names the windows, even for a session name with a space', async ({ page }) => {
	for (const key of [ACME, 'devbox/billing']) {
		const id = await fold(page, key).getAttribute('aria-controls');
		expect(id).toMatch(/^s-[A-Za-z0-9_.-]+$/);
		expect(await windows(page, key).getAttribute('id')).toBe(id);
		expect(await page.locator(`[id="${id}"]`).count()).toBe(1);
	}
});

test('sessions that no longer exist are dropped from storage on the next save', async ({
	page
}) => {
	await page.evaluate(() =>
		localStorage.setItem('mm.collapsed', JSON.stringify(['localhost/gone', 'devbox/old one']))
	);
	await page.reload();
	await openDrawer(page);
	await fold(page).click();
	expect(await page.evaluate(() => localStorage.getItem('mm.collapsed'))).toBe(
		JSON.stringify([ACME])
	);
});

test("folding another session leaves the open thread's session open", async ({ page }) => {
	// Stored as collapsed, then opened by its link before the list has loaded.
	await fold(page).click();
	await page.goto(threadPath(WAITING));
	await openDrawer(page);
	await expect(fold(page)).toHaveAttribute('aria-expanded', 'true');
	await fold(page, 'localhost/docs-site').click();
	await expect(fold(page, 'localhost/docs-site')).toHaveAttribute('aria-expanded', 'false');
	await expect(fold(page)).toHaveAttribute('aria-expanded', 'true');
	await expect(drawer(page).locator(`[data-thread="${WAITING}"]`)).toBeVisible();
});

test('the + on the header does not toggle the session', async ({ page }) => {
	const add = head(page).getByRole('button', { name: 'New window in acme-app' });
	// It is its own button beside the header button, not inside it.
	await expect(fold(page).locator('.add')).toHaveCount(0);
	// With session actions off on the Mac the ＋ is disabled: a tap does nothing.
	await add.click({ force: true });
	await expect(fold(page)).toHaveAttribute('aria-expanded', 'true');
	await expect(rows(page).first()).toBeVisible();

	await fold(page).click();
	await add.click({ force: true });
	await expect(fold(page)).toHaveAttribute('aria-expanded', 'false');
});

test('collapsed sessions survive a reload, per host and session', async ({ page }) => {
	await fold(page).click();
	await fold(page, 'devbox/billing').click();
	expect(await page.evaluate(() => localStorage.getItem('mm.collapsed'))).toBe(
		JSON.stringify(['devbox/billing', ACME])
	);

	await page.reload();
	await openDrawer(page);
	await expect(fold(page)).toHaveAttribute('aria-expanded', 'false');
	await expect(fold(page, 'devbox/billing')).toHaveAttribute('aria-expanded', 'false');
	await expect(fold(page, 'localhost/docs-site')).toHaveAttribute('aria-expanded', 'true');
	await expect(rows(page).first()).toBeHidden();
});

test('opening a thread from elsewhere expands its session', async ({ page }) => {
	await fold(page).click();
	await expect(fold(page)).toHaveAttribute('aria-expanded', 'false');
	await page.mouse.click(380, 400); // the scrim: close the drawer

	// The home board is "elsewhere": it opens the thread without the sidebar.
	// The board sits below the footer now, so the link is followed directly:
	// how the board is reached is the manager home's own test.
	await page.locator(`.item[data-thread="${WAITING}"]`).dispatchEvent('click');
	await expect(page).toHaveURL(/\/t\/localhost(:|%3A)1$/);
	await openDrawer(page);
	await expect(fold(page)).toHaveAttribute('aria-expanded', 'true');
	await expect(drawer(page).locator(`[data-thread="${WAITING}"]`)).toBeVisible();
	expect(await page.evaluate(() => localStorage.getItem('mm.collapsed'))).toBe('[]');

	// The user can still collapse the open thread's own session.
	await fold(page).click();
	await expect(fold(page)).toHaveAttribute('aria-expanded', 'false');
});

test('a thread opened by its link shows its session open, even when stored as collapsed', async ({
	page
}) => {
	await fold(page).click();
	await page.goto(threadPath(WAITING));
	await openDrawer(page);
	await expect(fold(page)).toHaveAttribute('aria-expanded', 'true');
	await expect(drawer(page).locator(`[data-thread="${WAITING}"]`)).toBeVisible();
});

test('the header is a 44pt target and the chevron turns', async ({ page }) => {
	const box = await fold(page).evaluate((el) => {
		const after = getComputedStyle(el, '::after');
		const rect = el.getBoundingClientRect();
		return rect.height - parseFloat(after.top) - parseFloat(after.bottom);
	});
	expect(box).toBeGreaterThanOrEqual(44);
	const turn = (): Promise<string> =>
		head(page)
			.locator('.chev')
			.evaluate((el) => getComputedStyle(el).transform);
	const open = await turn();
	await fold(page).click();
	await expect.poll(turn).not.toBe(open);
	await expect.poll(turn).toBe('none');
});

test('reduced motion: nothing animates', async ({ page }) => {
	await page.emulateMedia({ reducedMotion: 'reduce' });
	const durations = await page.evaluate(() =>
		['.windows', '.chev'].map(
			(selector) => getComputedStyle(document.querySelector(selector)!).transitionDuration
		)
	);
	for (const duration of durations) expect(duration).toMatch(/^0s/);
});

test('a session header stays at the top while its windows scroll, until the next one pushes it out', async ({
	page
}) => {
	// Short enough that one session is taller than the list.
	await page.setViewportSize({ width: 390, height: 360 });
	const scroller = drawer(page).locator('.scroll');
	const top = async (target: Locator): Promise<number> => (await target.boundingBox())?.y ?? -1;
	/** Scroll to `into` px past the top of the session `after` places below acme-app. */
	const scrollInto = (after: number, into: number): Promise<string> =>
		scroller.evaluate(
			(node, [key, after, into]) => {
				const all = [...node.querySelectorAll<HTMLElement>('.sess')];
				const mine = all.findIndex((sess) => sess.querySelector(`[data-session="${key}"]`));
				const sess = all[mine + (after as number)];
				node.scrollTop +=
					sess.getBoundingClientRect().top - node.getBoundingClientRect().top + (into as number);
				return sess.querySelector<HTMLElement>('.shead')?.dataset.session ?? '';
			},
			[ACME, after, into] as const
		);
	const rowHeight = (await rows(page).first().boundingBox())?.height ?? 0;
	expect(await rows(page).count()).toBeGreaterThan(2);

	// Past the header's own place and one row: without sticking it would be gone.
	await scrollInto(0, rowHeight + 40);
	await expect.poll(async () => (await top(head(page))) - (await top(scroller))).toBeCloseTo(0, 0);
	// It still folds its session from there.
	await expect(fold(page)).toHaveAttribute('aria-expanded', 'true');

	// Into the next session: its header is at the top and the first is out.
	const next = await scrollInto(1, 30);
	await expect
		.poll(async () => (await top(head(page, next))) - (await top(scroller)))
		.toBeCloseTo(0, 0);
	expect(await top(head(page))).toBeLessThan(await top(scroller));
});
