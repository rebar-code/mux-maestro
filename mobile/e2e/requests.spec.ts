import { mkdirSync } from 'node:fs';
import { expect, test, type Locator, type Page } from '@playwright/test';
import { fresh, touchDrag, WIDTH } from './helpers';

/** Screenshots are taken only when SHOTS names a directory outside the repo. */
async function shot(page: Page, name: string): Promise<void> {
	const dir = process.env.SHOTS;
	if (!dir) return;
	mkdirSync(dir, { recursive: true });
	await page.screenshot({ path: `${dir}/${name}.png` });
}

const rows = (page: Page): Locator => page.locator('[data-request]');
const box = (page: Page, title: string): Locator => page.getByRole('checkbox', { name: title });
const filter = (page: Page, name: 'Open' | 'Done'): Locator =>
	page.getByRole('button', { name: new RegExp(`^${name}( \\d+)?$`) });
const alertBlock = (page: Page): Locator => page.locator('[data-error]');

/** The state of one row as the Mac holds it. */
async function held(page: Page, id: string): Promise<string | undefined> {
	const response = await page.request.get('/__fixture/requests');
	const list = (await response.json()) as { requests: { id: string; state: string }[] };
	return list.requests.find((request) => request.id === id)?.state;
}

async function open(page: Page): Promise<void> {
	await fresh(page, '/requests');
	await expect(rows(page).first()).toBeVisible();
}

test('open rows are grouped by project, newest first, with no detail', async ({ page }) => {
	await open(page);
	await expect(page.locator('[data-project]')).toHaveText(['acme-app · 4', 'devbox · 3']);
	await expect(rows(page)).toHaveCount(7);
	expect(await rows(page).evaluateAll((all) => all.map((row) => row.dataset.request))).toEqual([
		'req-016',
		'req-018',
		'req-012',
		'req-014',
		'req-017',
		'req-019',
		'req-013'
	]);
	await expect(filter(page, 'Open')).toHaveText('Open 7');
	await expect(filter(page, 'Open')).toHaveAttribute('aria-pressed', 'true');
	await expect(filter(page, 'Done')).toHaveText('Done 2');
	// The chips: only for the states the checkbox does not say.
	await expect(page.locator('[data-request="req-016"] [data-state]')).toHaveText('in progress');
	await expect(page.locator('[data-request="req-013"] [data-state]')).toHaveText('blocked');
	await expect(page.locator('[data-request="req-012"] [data-state]')).toHaveText('review');
	await expect(page.locator('[data-request="req-018"] [data-state]')).toHaveText('parked');
	await expect(page.locator('[data-request="req-014"] [data-state]')).toHaveCount(0);
	// The title and the state are the row: nothing else from the file is drawn.
	await expect(page.getByText('Notes for', { exact: false })).toHaveCount(0);
	await expect(page.getByText('Waiting on new keys')).toHaveCount(0);
	await expect(page.getByText('Staging keys expire')).toHaveCount(0);
	await expect(page.getByText('old export format')).toHaveCount(0);
	await expect(page.getByRole('link', { name: 'Back' })).toBeVisible();
});

test('the Done filter shows the done rows', async ({ page }) => {
	await open(page);
	await filter(page, 'Done').click();
	await expect(filter(page, 'Done')).toHaveAttribute('aria-pressed', 'true');
	await expect(rows(page)).toHaveCount(2);
	await expect(box(page, 'Add proration to plan changes')).toHaveAttribute('aria-checked', 'true');
	await expect(box(page, 'Move the nightly backups to the new bucket')).toHaveAttribute(
		'aria-checked',
		'true'
	);
});

test('ticking a row writes done, and unticking writes todo', async ({ page }) => {
	await open(page);
	const title = 'Find why the build cache misses on every run';
	await box(page, title).click();
	await expect.poll(() => held(page, 'req-017')).toBe('done');
	await expect(box(page, title)).toHaveCount(0);
	await expect(filter(page, 'Open')).toHaveText('Open 6');
	await expect(filter(page, 'Done')).toHaveText('Done 3');

	await filter(page, 'Done').click();
	await expect(box(page, title)).toHaveAttribute('aria-checked', 'true');
	await box(page, title).click();
	await expect.poll(() => held(page, 'req-017')).toBe('todo');
	await expect(box(page, title)).toHaveCount(0);
	await filter(page, 'Open').click();
	await expect(box(page, title)).toHaveAttribute('aria-checked', 'false');
});

test('a list that does not parse shows an error, never rows; Retry recovers', async ({ page }) => {
	await fresh(page, '/requests');
	await page.request.post('/__fixture/requests-mode?value=corrupt');
	await page.reload();
	await expect(alertBlock(page)).toContainText("Can't read the request list");
	await expect(alertBlock(page)).toContainText('requests.json is not valid JSON');
	await expect(rows(page)).toHaveCount(0);
	await expect(page.locator('.empty')).toHaveCount(0);
	await expect(filter(page, 'Open')).toHaveText('Open');

	await page.request.post('/__fixture/requests-mode?value=ok');
	await page.getByRole('button', { name: 'Retry' }).click();
	await expect(rows(page)).toHaveCount(7);
	await expect(alertBlock(page)).toHaveCount(0);
});

test('a failed write leaves the row unticked and says so', async ({ page }) => {
	await open(page);
	await page.request.post('/__fixture/requests-fail?status=409&error=busy');
	const title = 'Turn on log retention for the worker';
	await box(page, title).click();
	await expect(page.getByRole('alert')).toHaveText('The request list is being written');
	await expect(box(page, title)).toHaveAttribute('aria-checked', 'false');
	await expect(box(page, title)).toBeEnabled();
	expect(await held(page, 'req-019')).toBe('in_progress');
	await expect(filter(page, 'Open')).toHaveText('Open 7');
});

test('a change made on the Mac shows when the page is back on screen', async ({ page }) => {
	await open(page);
	const title = 'Shorten every onboarding step label to two words';
	await expect(box(page, title)).toBeVisible();
	await page.request.post('/__fixture/requests-set?id=req-014&state=done');
	await page.evaluate(() => document.dispatchEvent(new Event('visibilitychange')));
	await expect(box(page, title)).toHaveCount(0);
	await expect(filter(page, 'Done')).toHaveText('Done 3');

	await shot(page, 'requests-open');
	await filter(page, 'Done').click();
	await expect(box(page, title)).toHaveAttribute('aria-checked', 'true');
	await shot(page, 'requests-done');
	await page.request.post('/__fixture/requests-mode?value=corrupt');
	await page.reload();
	await expect(alertBlock(page)).toBeVisible();
	await shot(page, 'requests-error');
});

/** The title button of one row: what opens its history. */
const opener = (page: Page, id: string): Locator =>
	page.locator(`[data-request="${id}"] button[aria-expanded]`);
const historyOf = (page: Page, id: string): Locator =>
	page.locator(`[data-request="${id}"] [data-history]`);
const entries = (page: Page, id: string): Locator => historyOf(page, id).locator('[data-by]');

test('a closed list shows no history; a title opens and closes its row history', async ({
	page
}) => {
	await open(page);
	await expect(page.locator('[data-history]')).toHaveCount(0);
	await expect(page.getByText('I misread the ask')).toHaveCount(0);
	await expect(page.getByText('runs out of memory')).toHaveCount(0);
	await expect(opener(page, 'req-016')).toHaveAttribute('aria-expanded', 'false');

	await opener(page, 'req-016').click();
	await expect(opener(page, 'req-016')).toHaveAttribute('aria-expanded', 'true');
	const id = await opener(page, 'req-016').getAttribute('aria-controls');
	await expect(historyOf(page, 'req-016')).toHaveAttribute('id', id ?? '');
	// In file order: the original ask first, the newest entry last.
	await expect(entries(page, 'req-016')).toHaveCount(4);
	expect(
		await entries(page, 'req-016').evaluateAll((all) => all.map((entry) => entry.dataset.by))
	).toEqual(['me', 'maestro', 'me', 'maestro']);
	const first = entries(page, 'req-016').first();
	await expect(first.locator('blockquote')).toContainText('runs out of memory on big accounts');
	await expect(first.locator('blockquote')).toHaveText(/^“.*”$/);
	const last = entries(page, 'req-016').last();
	await expect(last.locator('blockquote')).toHaveCount(0);
	await expect(last.locator('p')).toHaveText(
		'I misread the ask as paging. Removed the pages; the export now streams one file row by row.'
	);
	// The human's and the agent's entries do not look alike.
	const color = (entry: Locator): Promise<string> =>
		entry.locator('b').evaluate((label) => getComputedStyle(label).color);
	expect(await color(first)).not.toBe(await color(last));
	// Only this row opened.
	await expect(page.locator('[data-history]')).toHaveCount(1);

	await opener(page, 'req-016').click();
	await expect(historyOf(page, 'req-016')).toHaveCount(0);
	await expect(opener(page, 'req-016')).toHaveAttribute('aria-expanded', 'false');
});

test('an open history stays open across a refresh and a tick on another row', async ({ page }) => {
	await open(page);
	await opener(page, 'req-016').click();
	await opener(page, 'req-013').click();
	await expect(page.locator('[data-history]')).toHaveCount(2);

	await page.request.post('/__fixture/requests-set?id=req-014&state=done');
	await page.evaluate(() => document.dispatchEvent(new Event('visibilitychange')));
	await expect(box(page, 'Shorten every onboarding step label to two words')).toHaveCount(0);
	await expect(entries(page, 'req-016')).toHaveCount(4);
	await expect(entries(page, 'req-013')).toHaveCount(2);

	await box(page, 'Find why the build cache misses on every run').click();
	await expect.poll(() => held(page, 'req-017')).toBe('done');
	await expect(filter(page, 'Done')).toHaveText('Done 4');
	await expect(entries(page, 'req-016')).toHaveCount(4);
	await expect(entries(page, 'req-013')).toHaveCount(2);
});

test('a tick adds the Mac entry to that row history', async ({ page }) => {
	await open(page);
	await box(page, 'Find why the build cache misses on every run').click();
	await expect.poll(() => held(page, 'req-017')).toBe('done');
	await filter(page, 'Done').click();
	await opener(page, 'req-017').click();
	await expect(entries(page, 'req-017')).toHaveCount(2);
	await expect(entries(page, 'req-017').first().locator('blockquote')).toBeVisible();
	await expect(entries(page, 'req-017').last()).toHaveAttribute('data-by', 'me');
	await expect(entries(page, 'req-017').last().locator('p')).toHaveText(
		'State changed from todo to done on the phone.'
	);
});

test('a list with no history opens to one line, and nothing on the page edits', async ({
	page
}) => {
	await open(page);
	await expect(page.locator('input, textarea, [contenteditable]')).toHaveCount(0);
	await opener(page, 'req-016').click();
	await expect(page.locator('input, textarea, [contenteditable]')).toHaveCount(0);

	// A schema 1 list: no `history` on any row.
	await page.route('**/api/requests', async (route) => {
		const response = await route.fetch();
		const list = (await response.json()) as { requests: Record<string, unknown>[] };
		for (const request of list.requests) delete request.history;
		await route.fulfill({ response, json: { ...list, schema: 1 } });
	});
	await page.reload();
	await opener(page, 'req-012').click();
	await expect(historyOf(page, 'req-012')).toHaveText('No history');
});

test('the misread and corrected request, opened', async ({ page }) => {
	await open(page);
	await opener(page, 'req-016').click();
	await expect(entries(page, 'req-016')).toHaveCount(4);
	// Let the caret finish turning.
	await page.waitForTimeout(300);
	await shot(page, 'requests-history');
});

/** A tab of the Maestro screen, and its page. */
const tab = (page: Page, name: string): Locator => page.locator(`[data-tab="${name}"]`);
const pageOf = (page: Page, name: string): Locator => page.locator(`[data-page="${name}"]`);
const shows = (page: Page, name: string): Promise<void> =>
	expect(pageOf(page, name)).not.toHaveAttribute('inert', '');

/** The Maestro screen, on its Requests tab. */
async function openTab(page: Page): Promise<void> {
	await fresh(page);
	await shot(page, 'maestro-tabs');
	await tab(page, 'requests').click();
	await shows(page, 'requests');
	await expect(rows(page).first()).toBeVisible();
}

test('the Maestro screen has a Requests tab beside Chat and Board, with the list', async ({
	page
}) => {
	await openTab(page);
	await expect(page.locator('[data-tab]')).toHaveText([/Chat/, 'Board', 'Requests']);
	await expect(tab(page, 'requests')).toHaveAttribute('aria-selected', 'true');
	const list = pageOf(page, 'requests');
	await expect(list.locator('[data-project]')).toHaveText(['acme-app · 4', 'devbox · 3']);
	await expect(list.locator('[data-request]')).toHaveCount(7);
	await expect(filter(page, 'Open')).toHaveText('Open 7');
	// The tab strip names the page: the list has no title bar and no way back of its own.
	await expect(page.getByRole('link', { name: 'Back' })).toHaveCount(0);
	// The text box stays under it.
	await expect(page.locator('[data-foot] textarea')).toBeInViewport();
	// Let the pager come to rest on its third page.
	await expect
		.poll(() =>
			page.locator('.track').evaluate((el) => Math.round(el.getBoundingClientRect().left))
		)
		.toBe(-2 * WIDTH);
	await shot(page, 'maestro-requests');
});

test('on the tab a tick is written, the filter shows the done rows and a title opens its history', async ({
	page
}) => {
	await openTab(page);
	const title = 'Find why the build cache misses on every run';
	await box(page, title).click();
	await expect(box(page, title)).toHaveCount(0);
	expect(await held(page, 'req-017')).toBe('done');
	await filter(page, 'Done').click();
	await expect(rows(page)).toHaveCount(3);
	await expect(box(page, title)).toHaveAttribute('aria-checked', 'true');

	await filter(page, 'Open').click();
	await opener(page, 'req-016').click();
	await expect(entries(page, 'req-016')).toHaveCount(4);
	await opener(page, 'req-016').click();
	await expect(historyOf(page, 'req-016')).toHaveCount(0);
});

test('a swipe moves between Board and Requests, and the refresh key reads the list again', async ({
	page
}) => {
	await fresh(page);
	await tab(page, 'board').click();
	await shows(page, 'board');
	await touchDrag(page, [330, 420], [60, 420]);
	await shows(page, 'requests');
	await expect(tab(page, 'requests')).toHaveAttribute('aria-selected', 'true');
	await expect(rows(page)).toHaveCount(7);

	await page.request.post('/__fixture/requests-set?id=req-014&state=done');
	await page.getByRole('button', { name: 'Refresh' }).click();
	await expect(rows(page)).toHaveCount(6);
	// A pull down on the list reads it again too.
	await page.request.post('/__fixture/requests-set?id=req-014&state=todo');
	await touchDrag(page, [200, 320], [200, 560]);
	await expect(rows(page)).toHaveCount(7);

	await touchDrag(page, [60, 420], [330, 420]);
	await shows(page, 'board');
});

test('a list that cannot be read shows the error and Retry on the tab', async ({ page }) => {
	await openTab(page);
	await page.request.post('/__fixture/requests-mode?value=corrupt');
	await page.getByRole('button', { name: 'Refresh' }).click();
	await expect(alertBlock(page)).toBeVisible();
	await expect(rows(page)).toHaveCount(0);
	await page.request.post('/__fixture/requests-mode?value=ok');
	await page.getByRole('button', { name: 'Retry' }).click();
	await expect(rows(page)).toHaveCount(7);
});

test('there is no Requests tab on a session, or with the Maestro off', async ({ page }) => {
	await fresh(page, '/t/localhost%3A1');
	await expect(tab(page, 'main')).toBeVisible();
	await expect(tab(page, 'requests')).toHaveCount(0);

	await page.request.post('/__fixture/capability?name=manager&on=0');
	await page.goto('/');
	await expect(page.locator('[data-foot]')).toBeVisible();
	await expect(tab(page, 'requests')).toHaveCount(0);
});
