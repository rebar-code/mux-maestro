import { expect, test, type Locator, type Page } from '@playwright/test';
import { fresh, threadPath, TOKEN_HEADER } from './helpers';

/** A session that stopped after a question in words: idle, and it still needs an answer. */
const ASKS = 'localhost:7';
/** A session that runs: where the Maestro panel is opened from. */
const RUNNING = 'localhost:3';
const KEY = 'point:localhost:acme-app';

const hook = (page: Page, path: string): Promise<unknown> =>
	page.request.post(path, { headers: TOKEN_HEADER });

/** The Maestro's chat on the home page. */
const chat = (page: Page): Locator => page.locator('[data-view="chat"]').first();
const card = (page: Page, scope: Locator = chat(page)): Locator => scope.locator('[data-card]');

const raise = (page: Page, more = ''): Promise<unknown> =>
	hook(
		page,
		`/__fixture/card?thread=${ASKS}&reason=asks whether to run the migration` +
			`&body=It adds two columns to invoices.${more}`
	);

/** The app as a phone that may reply to a session: an answer is a reply. */
async function open(page: Page, path = '/'): Promise<void> {
	await fresh(page, path);
	await hook(page, '/__fixture/capability?name=replies&on=1');
}

const acted = async (page: Page): Promise<unknown> =>
	(await page.request.post('/__fixture/acted', { headers: TOKEN_HEADER })).json();

/** The page of a session is open. A link writes the id as it is; `goto` encodes it. */
const onThread = (page: Page, id: string): Promise<void> =>
	expect.poll(() => decodeURIComponent(new URL(page.url()).pathname)).toBe(`/t/${id}`);

/** Mark the document, so a later check can tell a route change from a page load. */
const mark = (page: Page): Promise<void> =>
	page.evaluate(() => void ((window as unknown as { stayed: boolean }).stayed = true));
const stayed = (page: Page): Promise<boolean> =>
	page.evaluate(() => (window as unknown as { stayed?: boolean }).stayed === true);

test.describe('action cards', () => {
	test('a card shows in the Maestro thread as a title and its answers', async ({ page }) => {
		await open(page);
		await raise(page);
		const shown = card(page);
		await expect(shown).toBeInViewport();
		await expect(shown.locator('[data-card-name]')).toHaveText('acme-app · dark-mode');
		await expect(shown.locator('[data-card-title]')).toHaveText(
			'asks whether to run the migration'
		);
		await expect(shown.locator('[data-card-body]')).toHaveText('It adds two columns to invoices.');
		await expect(shown.getByRole('button')).toHaveText(['Yes', 'No']);
		// The answer goes to the session's thread: the card says which.
		await expect(shown).toHaveAttribute('data-source', ASKS);
		for (const button of await shown.getByRole('button').all()) {
			expect((await button.boundingBox())?.height).toBeGreaterThanOrEqual(44);
		}
		// The session is idle, and its pointer is still live: the question is open.
		await expect(page.locator('[data-board] [data-point]')).not.toHaveAttribute('data-stale');
		await page.screenshot({ path: 'test-results/shots/action-card.png' });
	});

	test('a tap sends the answer to the session that asked, not to the Maestro', async ({ page }) => {
		await open(page);
		await raise(page);
		const before = await page.request.get('/api/manager/chat', { headers: TOKEN_HEADER });
		const sent = page.waitForRequest((request) => request.url().endsWith('/api/manager/act'));
		await card(page).getByRole('button', { name: 'No' }).click();

		// The phone names the card and the button. The Mac holds the text and picks the pane.
		const body = (await sent).postDataJSON() as Record<string, unknown>;
		expect(Object.keys(body).sort()).toEqual(['action', 'card', 'key']);
		expect(body).toMatchObject({ key: KEY, action: 1 });

		await expect(card(page).locator('[data-card-answer]')).toHaveText('Sent · No');
		await expect(card(page).getByRole('button')).toHaveCount(0);
		await expect(card(page).locator('[data-card-failure]')).toHaveCount(0);
		expect(await acted(page)).toEqual([{ key: KEY, action: 1, label: 'No', thread: ASKS }]);
		// Nothing was said to the Maestro: its chat is as it was.
		const after = await page.request.get('/api/manager/chat', { headers: TOKEN_HEADER });
		expect(await after.json()).toEqual(await before.json());
		// Answered: the pointer no longer counts as one that needs the user.
		await expect(page.locator('[data-board] [data-point]')).toHaveAttribute('data-stale', 'done');
		await page.screenshot({ path: 'test-results/shots/action-card-sent.png' });

		// The answer is on the Mac's row: a reload shows it again.
		await page.reload();
		await expect(card(page).locator('[data-card-answer]')).toHaveText('Sent · No');
	});

	test('a tap that does not land says why on the card, and can be tried again', async ({
		page
	}) => {
		await open(page);
		await raise(page, '&refuse=busy&message=Thread is busy');
		await card(page).getByRole('button', { name: 'Yes' }).click();
		const failure = card(page).locator('[data-card-failure]');
		await expect(failure).toHaveText('Not sent · Thread is busy');
		await expect(failure).toHaveAttribute('role', 'alert');
		// Not answered: no "Sent", and both answers are still there to tap.
		await expect(card(page).locator('[data-card-answer]')).toHaveCount(0);
		await expect(card(page).getByRole('button')).toHaveText(['Yes', 'No']);
		expect(await acted(page)).toEqual([]);
		await page.screenshot({ path: 'test-results/shots/action-card-failed.png' });

		// The session is free again: the same tap lands, and the failure goes.
		await raise(page);
		await card(page).getByRole('button', { name: 'Yes' }).click();
		await expect(card(page).locator('[data-card-answer]')).toHaveText('Sent · Yes');
		await expect(failure).toHaveCount(0);
		expect(await acted(page)).toEqual([{ key: KEY, action: 0, label: 'Yes', thread: ASKS }]);
	});

	test('a failure with no reason from the Mac still shows', async ({ page }) => {
		await open(page);
		await raise(page, '&refuse=unavailable&status=503');
		await card(page).getByRole('button', { name: 'Yes' }).click();
		await expect(card(page).locator('[data-card-failure]')).toHaveText('Not sent · Not sent');
	});

	test('Go on a card opens the session inside the app', async ({ page }) => {
		await open(page);
		await raise(page);
		await expect(card(page)).toBeVisible();
		await mark(page);
		await card(page).locator('[data-go]').click();
		await onThread(page, ASKS);
		await expect(page.locator('.tbar .title b')).toHaveText('acme-app · dark-mode');
		// The same document: a route change, not a page load, and no other tab.
		expect(await stayed(page)).toBe(true);
		expect(page.context().pages()).toHaveLength(1);
	});

	test('a card that this build cannot read is still a pointer', async ({ page }) => {
		await open(page);
		await raise(page, '&v=2');
		await expect(page.locator('[data-board] [data-point]')).toHaveCount(1);
		await expect(card(page)).toHaveCount(0);
	});

	test('with replies off a card has no answers, only the way to the session', async ({ page }) => {
		await fresh(page);
		await raise(page);
		await expect(card(page).locator('[data-card-title]')).toBeVisible();
		await expect(card(page).getByRole('button')).toHaveCount(0);
		await expect(card(page).locator('[data-go]')).toBeVisible();
	});

	test("the header button of any page opens the Maestro's screen, with the card", async ({
		page
	}) => {
		await open(page, threadPath(RUNNING));
		await raise(page);
		await page.locator('[data-maestro]').click();
		await expect(page.locator('[data-foot]')).toBeVisible();
		await expect(card(page)).toHaveCount(1);
		await card(page).getByRole('button', { name: 'Yes' }).click();
		await expect(card(page).locator('[data-card-answer]')).toHaveText('Sent · Yes');
		expect(await acted(page)).toEqual([{ key: KEY, action: 0, label: 'Yes', thread: ASKS }]);
	});
});

test.describe('session links in the chat', () => {
	test('a muxmaestro link opens the session inside the app', async ({ page }) => {
		await fresh(page);
		// As the Maestro writes it: `mux link --target acme-app:7`.
		await hook(
			page,
			`/__fixture/maestro-say?text=${encodeURIComponent('Look at muxmaestro://open?session=acme-app&window=7&pane=%257 now.')}`
		);
		const link = chat(page).locator('[data-thread-link]');
		// The session's name, not its address.
		await expect(link).toHaveText('acme-app:7');
		await mark(page);
		await link.click();
		await onThread(page, ASKS);
		expect(await stayed(page)).toBe(true);
		expect(page.context().pages()).toHaveLength(1);
	});

	test('a link to a session that is gone stays on the page and shows it', async ({ page }) => {
		await fresh(page);
		await hook(
			page,
			`/__fixture/maestro-say?text=${encodeURIComponent('It was muxmaestro://open?session=reports-old&window=2 before.')}`
		);
		const link = chat(page).locator('[data-thread-link]');
		await expect(link).toHaveText('reports-old:2');
		await link.click();
		await expect(link).toHaveAttribute('data-missing', '');
		expect(new URL(page.url()).pathname).toBe('/');
	});
});
