import { expect, test, type Locator, type Page } from '@playwright/test';
import { drawer, expectDrawerClosed, expectDrawerOpen, fresh, threadPath } from './helpers';

const box = (page: Page): Locator => drawer(page).getByRole('searchbox', { name: 'Search' });
const results = (page: Page): Locator =>
	drawer(page).getByRole('dialog', { name: 'Search results' });
const sheet = (page: Page): Locator => page.locator('[data-action-sheet]');

test.beforeEach(async ({ page }) => {
	await fresh(page);
	await page.request.post('/__fixture/capability?name=sessionActions&on=1');
	await page.reload();
	await page.getByRole('button', { name: 'Menu' }).click();
	await expectDrawerOpen(page);
});

test('the search box sits between the filter and a small Maestro button', async ({ page }) => {
	const filter = await drawer(page).locator('[data-filter]').boundingBox();
	const search = await box(page).boundingBox();
	const maestro = await drawer(page).locator('[data-home]').boundingBox();
	expect(filter!.x + filter!.width).toBeLessThanOrEqual(search!.x);
	expect(search!.x + search!.width).toBeLessThanOrEqual(maestro!.x);
	expect(maestro!.width).toBeLessThanOrEqual(48);
	expect(search!.width).toBeGreaterThan(maestro!.width * 2);
	await expect(results(page)).toHaveCount(0);
});

test('a window that is found opens with a tap, and the search ends', async ({ page }) => {
	await box(page).fill('CHECKOUT');
	await expect(results(page)).toBeVisible();
	const rows = results(page).locator('[data-thread]');
	await expect(rows).toHaveCount(1);
	await expect(rows).toContainText('checkout-fix');
	await rows.click();
	await expect(page).toHaveURL(/\/t\/localhost:1$/);
	await expectDrawerClosed(page);
	await page.getByRole('button', { name: 'Menu' }).click();
	await expectDrawerOpen(page);
	await expect(box(page)).toHaveValue('');
	await expect(results(page)).toHaveCount(0);
});

test('a host that is found starts a new session from its ＋', async ({ page }) => {
	await box(page).fill('devbox');
	const host = results(page).locator('[data-found-host="devbox"]');
	await expect(host).toBeVisible();
	// Its sessions and windows are found with it.
	await expect(results(page).locator('[data-found-session="devbox/billing"]')).toBeVisible();
	await host.getByRole('button', { name: 'New session on devbox' }).click();
	await expect(sheet(page)).toHaveAttribute('data-action-sheet', 'dirs');
	await expect(results(page)).toHaveCount(0);
});

test('the word local finds this Mac', async ({ page }) => {
	await box(page).fill('local');
	await expect(results(page).locator('[data-found-host]')).toHaveCount(1);
	await expect(results(page).locator('[data-found-host="localhost"]')).toBeVisible();

	// The last window found scrolls clear of the bar.
	const last = results(page).locator('[data-thread]').last();
	await last.scrollIntoViewIfNeeded();
	const row = await last.boundingBox();
	const bar = await box(page).boundingBox();
	expect(row!.y + row!.height).toBeLessThanOrEqual(bar!.y);
});

test('a session that is found takes a new window from its ＋, and opens with a tap', async ({
	page
}) => {
	await box(page).fill('billing');
	const session = results(page).locator('[data-found-session="devbox/billing"]');
	await session.getByRole('button', { name: 'New window in billing' }).click();
	await expect(sheet(page)).toHaveAttribute('data-action-sheet', 'start');
	await page.keyboard.press('Escape');
	await expect(sheet(page)).toHaveCount(0);

	await box(page).fill('docs-site');
	await results(page).locator('[data-found-session="localhost/docs-site"] a').click();
	await expect(page).toHaveURL(/\/t\/localhost/);
	await expectDrawerClosed(page);
});

test('nothing found says so, and the ✕ ends the search', async ({ page }) => {
	await box(page).fill('zzz-nothing');
	await expect(results(page)).toHaveText('No matches');
	await drawer(page).getByRole('button', { name: 'Clear search' }).click();
	await expect(results(page)).toHaveCount(0);
	await expect(box(page)).toHaveValue('');
	// The list is back under it.
	await expect(drawer(page).getByText('checkout-fix')).toBeVisible();

	await box(page).fill('acme');
	await expect(results(page)).toBeVisible();
	await box(page).press('Escape');
	await expect(results(page)).toHaveCount(0);
});

test('without session actions the ＋ is off', async ({ page }) => {
	await page.request.post('/__fixture/capability?name=sessionActions&on=0');
	await page.reload();
	await page.getByRole('button', { name: 'Menu' }).click();
	await expectDrawerOpen(page);
	await box(page).fill('devbox');
	await expect(results(page).getByRole('button', { name: 'New session on devbox' })).toBeDisabled();
});

test('the small Maestro button opens the home page', async ({ page }) => {
	await fresh(page, threadPath('localhost:1'));
	await page.getByRole('button', { name: 'Menu' }).click();
	await expectDrawerOpen(page);
	await drawer(page).getByRole('link', { name: 'Maestro' }).click();
	await expect(page).toHaveURL(/\/$/);
	await expectDrawerClosed(page);
});
