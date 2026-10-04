import { expect, test } from '@playwright/test';
import {
	drag,
	dragStart,
	drawer,
	drawerOffset,
	expectDrawerClosed,
	expectDrawerOpen,
	fresh,
	touchDrag,
	WIDTH
} from './helpers';

test.beforeEach(async ({ page }) => {
	await fresh(page);
});

test('the menu button opens the drawer and the scrim closes it', async ({ page }) => {
	await expectDrawerClosed(page);
	await page.getByRole('button', { name: 'Menu' }).click();
	await expectDrawerOpen(page);
	await expect(drawer(page).getByText('checkout-fix')).toBeVisible();
	await page.mouse.click(WIDTH - 10, 400);
	await expectDrawerClosed(page);
});

test('a right drag opens the drawer and follows the finger', async ({ page }) => {
	const width = WIDTH * 0.86;
	await dragStart(page, [40, 500], [190, 505]);
	// Mid-drag: partly out, moved by about what the finger moved (less the 10px slop).
	const offset = await drawerOffset(page);
	expect(offset).toBeGreaterThan(width - 150 - 2);
	expect(offset).toBeLessThan(width - 130);
	await page.mouse.move(260, 505, { steps: 6 });
	expect(await drawerOffset(page)).toBeLessThan(offset);
	await page.waitForTimeout(120);
	await page.mouse.up();
	await expectDrawerOpen(page);
});

test('a finger opens and closes the drawer over scrolling content', async ({ page }) => {
	await touchDrag(page, [40, 500], [300, 506]);
	await expectDrawerOpen(page);
	// Starts on a row inside the scrolling list.
	await touchDrag(page, [280, 300], [40, 304]);
	await expectDrawerClosed(page);
});

test('a short slow drag springs back', async ({ page }) => {
	await drag(page, [40, 500], [110, 500]);
	await expectDrawerClosed(page);
});

test('a left drag closes the drawer and follows the finger', async ({ page }) => {
	await page.getByRole('button', { name: 'Menu' }).click();
	await expectDrawerOpen(page);
	await dragStart(page, [300, 500], [180, 500]);
	const offset = await drawerOffset(page);
	expect(offset).toBeGreaterThan(100);
	expect(offset).toBeLessThan(120);
	await page.mouse.move(100, 500, { steps: 6 });
	await page.waitForTimeout(120);
	await page.mouse.up();
	await expectDrawerClosed(page);
});

test('a drag that ends on a row does not open it', async ({ page }) => {
	await page.getByRole('button', { name: 'Menu' }).click();
	await expectDrawerOpen(page);
	await drag(page, [200, 300], [150, 300]);
	await expectDrawerOpen(page);
	await expect(page).toHaveURL(/\/$/);
});

test('a vertical drag scrolls and leaves the drawer alone', async ({ page }) => {
	await drag(page, [200, 300], [205, 600]);
	await expectDrawerClosed(page);
});

test('grouping: Most Recent by default, then Host and Directory, and the pick is kept', async ({
	page
}) => {
	await page.getByRole('button', { name: 'Menu' }).click();
	const heads = drawer(page).locator('.shead b');
	const sects = drawer(page).locator('.scroll > .sect:not([data-hosts])');

	await expect(page.getByRole('tab', { name: 'Most Recent' })).toHaveAttribute(
		'aria-selected',
		'true'
	);
	await expect(sects).toHaveCount(0);
	// Ordered by the last input: docs-site (40s), acme-app (2m), infra (5m), billing (6m).
	await expect(heads.nth(0)).toHaveText('docs-site');
	await expect(heads.nth(1)).toHaveText('acme-app');
	await expect(heads.nth(2)).toHaveText('infra');
	await expect(heads.nth(3)).toHaveText('billing');
	// Inside a session too: checkout-fix (2m) before onboarding-copy (3m).
	const order = await drawer(page)
		.locator('[data-thread]')
		.evaluateAll((rows) => rows.map((row) => row.getAttribute('data-thread')));
	expect(order.indexOf('localhost:1')).toBeLessThan(order.indexOf('localhost:4'));
	expect(order.indexOf('localhost:4')).toBeLessThan(order.indexOf('localhost:7'));

	await page.getByRole('tab', { name: 'Host' }).click();
	await expect(sects).toHaveText(['localhost', 'devbox', 'buildbox']);
	await expect(heads.nth(0)).toHaveText('acme-app');
	await expect(heads.nth(1)).toHaveText('billing');

	await page.getByRole('tab', { name: 'Directory' }).click();
	await expect(sects.first()).toHaveText('~/code/acme-app');
	await expect(sects.filter({ hasText: '~/code/billing' })).toHaveCount(2);

	await page.reload();
	await page.getByRole('button', { name: 'Menu' }).click();
	await expect(page.getByRole('tab', { name: 'Directory' })).toHaveAttribute(
		'aria-selected',
		'true'
	);
});

test('grouping: the server default applies until this phone picks one', async ({ page }) => {
	await page.request.post('/__fixture/grouping?value=host');
	await page.reload();
	await page.getByRole('button', { name: 'Menu' }).click();
	await expect(page.getByRole('tab', { name: 'Host' })).toHaveAttribute('aria-selected', 'true');

	await page.getByRole('tab', { name: 'Most Recent' }).click();
	await page.reload();
	await page.getByRole('button', { name: 'Menu' }).click();
	await expect(page.getByRole('tab', { name: 'Most Recent' })).toHaveAttribute(
		'aria-selected',
		'true'
	);
});

test('rows show status, sleep and yawn tags, last prompt, age and host colour', async ({
	page
}) => {
	await page.getByRole('button', { name: 'Menu' }).click();
	const row = (id: string) => drawer(page).locator(`[data-thread="${id}"]`);

	const waiting = row('localhost:1');
	await expect(waiting.locator('.dot')).toHaveClass(/waiting/);
	await expect(waiting.locator('.prompt')).toHaveText(
		'fix the failing checkout test and open a PR'
	);
	await expect(waiting.locator('.age')).toHaveText('2m');
	await expect(waiting.locator('.why')).toHaveText('needs you');
	await expect(waiting).toHaveCSS('border-left-color', 'rgb(50, 145, 255)');

	await expect(row('localhost:3').locator('.dot')).toHaveClass(/busy/);
	await expect(row('localhost:9').locator('.age')).toHaveText('🥱 52m');
	await expect(row('localhost:100').locator('.age')).toHaveText('💤 2h');
	await expect(row('devbox:2')).toHaveCSS('border-left-color', 'rgb(245, 166, 35)');

	const chip = drawer(page).locator('[data-session="devbox/billing"] .host');
	await expect(chip).toHaveText('devbox');
	await expect(chip).toHaveCSS('color', 'rgb(245, 166, 35)');
	await expect(drawer(page).locator('.badge')).toHaveText('2');
});

test('hosts section: every host with colour, thread count and stats', async ({ page }) => {
	await page.getByRole('button', { name: 'Menu' }).click();
	await drawer(page).locator('[data-hosts]').scrollIntoViewIfNeeded();
	await expect(drawer(page).locator('[data-hosts]')).toHaveText('Hosts · 3');

	const local = drawer(page).locator('[data-host="localhost"]');
	await expect(local.locator('.hname')).toHaveCSS('color', 'rgb(50, 145, 255)');
	await expect(local.locator('.cnt')).toHaveText('16 threads');
	await expect(local.locator('.stats span')).toHaveText([
		'CPU 38%',
		'load 0.31/core',
		'21 / 32 GB',
		'212 GB free'
	]);

	const build = drawer(page).locator('[data-host="buildbox"]');
	await expect(build.locator('.cnt')).toHaveText('1 thread');
	// Above 65% the bar turns amber.
	await expect(build.locator('.bar i')).toHaveCSS('background-color', 'rgb(245, 166, 35)');
	await expect(drawer(page).locator('[data-host="devbox"] .stats')).toContainText('1.4 TB free');
});

test('controls that arrive later are drawn but do nothing', async ({ page }) => {
	await expect(page.getByRole('button', { name: 'Talk', exact: true })).toBeDisabled();
	await page.getByRole('button', { name: 'Menu' }).click();
	await expect(page.getByRole('button', { name: 'New window in acme-app' })).toBeDisabled();
	await drawer(page).locator('[data-hosts]').scrollIntoViewIfNeeded();
	await expect(page.getByRole('button', { name: 'New session on devbox' })).toBeDisabled();
	await expect(page.getByRole('button', { name: 'New session on devbox' })).toHaveAttribute(
		'aria-disabled',
		'true'
	);
});

test('home: status chips and the threads that need you, live', async ({ page }) => {
	await expect(page.locator('.chip')).toHaveText(['2 need you', '4 running', '💤 14']);
	const cards = page.locator('.item[data-thread]');
	await expect(cards).toHaveCount(2);
	// The cards are on the board, under the footer: raise it.
	await page.locator('[data-grab]').click();
	await expect(page.locator('[data-board]')).toHaveAttribute('data-stop', '1');
	await page.waitForTimeout(450);

	// A live update lands without moving what is already on screen.
	const first = cards.first();
	const before = await first.boundingBox();
	await page.request.post('/__fixture/wait?id=localhost:3');
	await expect(page.locator('.chip').first()).toHaveText('3 need you');
	await expect(cards).toHaveCount(3);
	expect(await first.boundingBox()).toEqual(before);

	await first.click();
	await expect(page).toHaveURL(/\/t\/localhost(:|%3A)1$/);
});

test('touch targets are at least 44pt tall', async ({ page }) => {
	await page.getByRole('button', { name: 'Menu' }).click();
	await expectDrawerOpen(page);
	const sizes = await page.evaluate(() => {
		const hit = (el: Element): number => {
			const own = el.getBoundingClientRect().height;
			const after = parseFloat(getComputedStyle(el, '::after').height);
			return Math.max(own, Number.isNaN(after) ? 0 : after);
		};
		return [...document.querySelectorAll('[data-drawer] :is(a, button)')].map((el) => ({
			label: (el.getAttribute('aria-label') ?? el.textContent ?? '').trim().slice(0, 30),
			height: hit(el)
		}));
	});
	expect(sizes.length).toBeGreaterThan(20);
	expect(sizes.filter((size) => size.height < 44)).toEqual([]);
});
