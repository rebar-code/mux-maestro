import { expect, test, type Page } from '@playwright/test';
import { forget, fresh, pairingLink, reset, threadPath } from './helpers';

// The phone's own log, as the Mac receives it: what reaches `/api/log`.

/** A thread on localhost, in tmux session `acme-app`. */
const LOCAL = 'localhost:1';
const LOCAL_SESSION = 'acme-app';

type LogLine = Record<string, unknown> & { sid: string; build: string; kind: string; msg: string };
interface Batch {
	sid: string;
	build: string;
	lines: Record<string, unknown>[];
}

async function batches(page: Page): Promise<Batch[]> {
	return ((await (await page.request.get('/__fixture/logs')).json()) as { batches: Batch[] })
		.batches;
}

/** Every line the fixture received, each with its batch's `sid` and `build`. */
async function logLines(page: Page): Promise<LogLine[]> {
	return (await batches(page)).flatMap((batch) =>
		batch.lines.map((line) => ({ ...line, sid: batch.sid, build: batch.build }) as LogLine)
	);
}

/** The first received line that matches, once it has arrived. */
async function lineWhere(
	page: Page,
	match: (line: LogLine) => boolean,
	timeout = 15_000
): Promise<LogLine> {
	let found: LogLine | undefined;
	await expect
		.poll(
			async () => {
				found = (await logLines(page)).find(match);
				return found !== undefined;
			},
			{ timeout }
		)
		.toBe(true);
	return found as LogLine;
}

async function pageVersion(page: Page): Promise<string> {
	return ((await (await page.request.get('/_app/version.json')).json()) as { version: string })
		.version;
}

async function open(page: Page, path: string, on: string[] = []): Promise<void> {
	await reset(page);
	for (const name of on) await page.request.post(`/__fixture/capability?name=${name}&on=1`);
	await forget(page);
	await page.goto(pairingLink(path));
}

/** The app goes to the background. */
async function background(page: Page): Promise<void> {
	await page.evaluate(() => {
		Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => 'hidden' });
		document.dispatchEvent(new Event('visibilitychange'));
	});
}

/** Which build the page runs: the fixture marks the shell of a newer one. */
const build = (page: Page): Promise<string | null> =>
	page
		.evaluate(
			() => document.querySelector('meta[name="mm-build"]')?.getAttribute('content') ?? null
		)
		// The page is reloading under the question: ask again.
		.catch(() => null);

const boom = (page: Page, message: string): Promise<void> =>
	page.evaluate((text) => {
		setTimeout(() => {
			throw new Error(text);
		}, 0);
	}, message);

test('a page load sends a session line that describes the device and the build', async ({
	page
}) => {
	await fresh(page);
	const line = await lineWhere(page, (l) => l.kind === 'session');
	expect(line.build).toBe(await pageVersion(page));
	expect(line.sid).toMatch(/^[a-z0-9]+$/);
	expect(line.viewport).toBe('390x844@3');
	expect(typeof line.standalone).toBe('boolean');
	expect(typeof line.net).toBe('string');
	expect(line.ios).toBe('18.0');
});

test('a thrown error is sent with its stack and the project on screen', async ({ page }) => {
	await fresh(page, threadPath(LOCAL));
	await expect(page.locator('.tbar .title b')).toHaveText('acme-app · checkout-fix');
	await boom(page, 'boom from e2e');
	const line = await lineWhere(
		page,
		(l) => l.kind === 'error' && String(l.msg).includes('boom from e2e')
	);
	expect(line.sev).toBe('error');
	expect(typeof line.stack).toBe('string');
	expect(String(line.stack)).toContain('boom from e2e');
	expect(line.project).toBe(LOCAL_SESSION);
	expect(line.host).toBe('localhost');
	expect(line.build).toBe(await pageVersion(page));
});

test('an unhandled rejection is sent', async ({ page }) => {
	await fresh(page);
	await page.evaluate(() => {
		void Promise.reject(new Error('rejected in e2e'));
	});
	const line = await lineWhere(
		page,
		(l) => l.kind === 'rejection' && String(l.msg).includes('rejected in e2e')
	);
	expect(line.sev).toBe('error');
	expect(line.name).toBe('Error');
});

test('a failed API call is sent without its query, and the log never logs itself', async ({
	page
}) => {
	await open(page, threadPath(LOCAL), ['find']);
	await page.route('**/api/threads/*/find*', (route) =>
		route.fulfill({ status: 500, contentType: 'application/json', body: '{"error":"boom"}' })
	);
	await page.getByRole('tab').click();
	await expect(page.locator('[data-view="terminal"]')).toBeVisible();
	await page.getByRole('button', { name: 'Find' }).click();
	await page.getByRole('searchbox', { name: 'Find in session' }).fill('QUERY-IN-URL-7');

	const line = await lineWhere(page, (l) => l.kind === 'fetch' && l.status === 500);
	expect(line.url).toBe(`/api/threads/${encodeURIComponent(LOCAL)}/find`);
	expect(line.method).toBe('GET');
	expect(typeof line.ms).toBe('number');
	expect(line.sev).toBe('error');
	expect(line.project).toBe(LOCAL_SESSION);
	expect(String(line.msg)).not.toContain('?');

	// More lines, so more requests to `/api/log` are made and answered.
	await boom(page, 'one more line');
	await lineWhere(page, (l) => String(l.msg).includes('one more line'));
	const all = await logLines(page);
	expect(all.filter((l) => l.kind === 'fetch' && l.url === '/api/log')).toEqual([]);
	expect(JSON.stringify(await batches(page))).not.toContain('QUERY-IN-URL-7');
});

test('a page that goes to the background sends what it holds at once', async ({ page }) => {
	await fresh(page);
	// Wait out the first batch, so what follows is held by the debounce.
	await lineWhere(page, (l) => l.kind === 'session');
	await boom(page, 'error before hiding');
	await background(page);
	// Well inside the 2 s the debounce would wait.
	const hidden = await lineWhere(page, (l) => l.kind === 'life' && l.msg === 'hidden', 1500);
	const error = await lineWhere(page, (l) => String(l.msg).includes('error before hiding'), 1500);
	expect(error.kind).toBe('error');
	expect(hidden.sid).toBe(error.sid);
});

test('nothing a person typed is in the log', async ({ page }) => {
	await open(page, threadPath(LOCAL), ['replies', 'find']);
	const box = page.getByRole('textbox', { name: 'Reply' });
	await box.fill('SECRET-TYPED-TEXT-42');
	await page.getByRole('button', { name: 'Find' }).click();
	await page.getByRole('searchbox', { name: 'Find in session' }).fill('SECRET-FIND-QUERY-43');
	await boom(page, 'error after typing');
	await background(page);
	await lineWhere(page, (l) => String(l.msg).includes('error after typing'));
	await lineWhere(page, (l) => l.kind === 'life' && l.msg === 'hidden');
	const sent = JSON.stringify(await batches(page));
	expect(sent).not.toContain('SECRET-TYPED-TEXT-42');
	expect(sent).not.toContain('SECRET-FIND-QUERY-43');
});

test('a new worker taking over is in the log, the lines before its reload too', async ({
	page
}) => {
	await open(page, threadPath('localhost:7'), ['replies']);
	await page.evaluate(() => navigator.serviceWorker.ready);
	await page.reload();
	await expect
		.poll(() => page.evaluate(() => Boolean(navigator.serviceWorker.controller)))
		.toBe(true);
	// The worker's own update check is over.
	await page.waitForTimeout(3000);

	await page.request.post('/__fixture/build?tag=obs');
	await page.evaluate(() => document.dispatchEvent(new Event('visibilitychange')));

	// The first worker took control once already: only what follows the update counts.
	const afterUpdate = async (): Promise<string[]> => {
		const messages = (await logLines(page)).filter((l) => l.kind === 'sw').map((l) => l.msg);
		const found = messages.indexOf('new worker found');
		return found < 0 ? [] : messages.slice(found);
	};
	await expect
		.poll(afterUpdate, { timeout: 20_000 })
		.toEqual(
			expect.arrayContaining([
				'new worker found',
				expect.stringMatching(/installed/),
				'another worker took control'
			])
		);
	// The page reloads for the new build: the lines from before it still arrived.
	await expect.poll(() => build(page), { timeout: 20_000 }).toBe('obs');
	// Three page loads: the first visit, the reload under the worker, the new build.
	await expect
		.poll(async () => (await logLines(page)).filter((l) => l.kind === 'session').length)
		.toBe(3);
	const all = await logLines(page);
	const reloaded = all.filter((l) => l.kind === 'session').at(-1) as LogLine;
	const found = all.find((l) => l.kind === 'sw' && l.msg === 'new worker found') as LogLine;
	// Sent by the page before the reload, not by the one after it.
	expect(found.sid).not.toBe(reloaded.sid);
});
