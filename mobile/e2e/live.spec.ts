import { expect, test, type Locator, type Page } from '@playwright/test';
import { fresh, threadPath } from './helpers';

// A remote pane: its first tab is the terminal.
const PANE = 'buildbox:8';

const chip = (page: Page): Locator => page.locator('.livechip');
const liveView = (page: Page): Locator => page.locator('[data-view="live"]');
const captured = (page: Page): Locator => page.locator('[data-view="terminal"]');
const rows = (page: Page): Locator => page.locator('[data-view="live"] .xterm-rows');
const key = (page: Page, name: string): Locator =>
	page.locator('[data-keybar]').getByRole('button', { name, exact: true });

interface Fixture {
	typed: string;
	opens: { url: string; token: string | null; protocol: string | null }[];
	sockets: number;
}

async function fixture(page: Page): Promise<Fixture> {
	return (await page.request.post('/__fixture/terminal')).json();
}

declare global {
	interface Window {
		__violations: string[];
	}
}

/** Open the pane with the live terminal switched on (or not). */
async function open(page: Page, on = true): Promise<string[]> {
	const problems: string[] = [];
	page.on('console', (message) => {
		if (message.type() === 'error') problems.push(message.text());
	});
	page.on('pageerror', (error) => problems.push(String(error)));
	await page.addInitScript(() => {
		window.__violations = [];
		document.addEventListener('securitypolicyviolation', (event) => {
			window.__violations.push(`${event.violatedDirective} ${event.blockedURI}`);
		});
	});
	await fresh(page, '/');
	if (on) await page.request.post('/__fixture/capability?name=liveTerminal&on=1');
	await page.goto(threadPath(PANE));
	return problems;
}

async function live(page: Page): Promise<string[]> {
	const problems = await open(page);
	await expect(chip(page)).toHaveAttribute('data-live', 'live');
	await expect(rows(page)).toContainText('me@devbox acme-app %');
	return problems;
}

test('with the switch off the captured view is all there is', async ({ page }) => {
	await open(page, false);
	await expect(page.locator('.ln').last()).toBeInViewport();
	await expect(chip(page)).toHaveCount(0);
	await expect(liveView(page)).toHaveCount(0);
	expect((await fixture(page)).opens).toHaveLength(0);
});

test('live mode connects and draws the pane, with no policy violation', async ({ page }) => {
	const problems = await live(page);
	await expect(chip(page)).toHaveText('Live');
	await expect(chip(page)).toHaveAttribute('aria-pressed', 'true');
	// The terminal took the captured view's place.
	await expect(captured(page)).toHaveCount(0);
	await expect(liveView(page)).toBeVisible();
	await expect(rows(page)).toContainText('build 080');

	// The token is not in the address, in a header or in a subprotocol.
	const { opens, sockets } = await fixture(page);
	expect(sockets).toBe(1);
	expect(opens).toEqual([
		{ url: `/api/terminal/${encodeURIComponent(PANE)}`, token: null, protocol: null }
	]);

	// Output from the pane arrives by itself.
	await page.request.post(`/__fixture/terminal-say?text=${encodeURIComponent('deploy ok\r\n')}`);
	await expect(rows(page)).toContainText('deploy ok');

	expect(await page.evaluate(() => window.__violations)).toEqual([]);
	expect(problems).toEqual([]);
	await page.screenshot({ path: 'test-results/shots/live-terminal.png' });
});

test('the terminal keeps the pane width and scrolls, sideways and into scrollback', async ({
	page
}) => {
	await live(page);
	// 100 columns do not fit 390 px: the pane is not resized, the view scrolls.
	const pin = page.locator('[data-pin]');
	const { wide, view } = await pin.evaluate((el) => ({
		wide: el.scrollWidth,
		view: el.clientWidth
	}));
	expect(wide).toBeGreaterThan(view);
	expect(await page.locator('[data-view="live"] .xterm-rows > div').count()).toBe(30);

	// The prompt's line is in view at the start.
	const prompt = rows(page).locator('div', { hasText: 'me@devbox acme-app %' }).last();
	await expect(prompt).toBeInViewport();

	// The page scrolls with the browser's own scrolling, back to the first line.
	await liveView(page).evaluate((el) => el.scrollTo(0, 0));
	await expect(rows(page)).toContainText('build 001');
	await expect(page.getByRole('button', { name: 'Jump to bottom' })).toBeVisible();
	await page.getByRole('button', { name: 'Jump to bottom' }).click();
	await expect(prompt).toBeInViewport();
	await expect(page.getByRole('button', { name: 'Jump to bottom' })).toHaveCount(0);
});

test('the text size buttons change the terminal text', async ({ page }) => {
	await live(page);
	const size = (): Promise<string> => rows(page).evaluate((el) => getComputedStyle(el).fontSize);
	const before = parseFloat(await size());
	await page.getByRole('button', { name: 'Larger text' }).click();
	await expect.poll(async () => parseFloat(await size())).toBe(before + 1);
	// The size is the stored one: a new visit starts with it.
	await page.reload();
	await expect(chip(page)).toHaveAttribute('data-live', 'live');
	await expect.poll(async () => parseFloat(await size())).toBe(before + 1);
});

test('the key bar and the keyboard type through the socket', async ({ page }) => {
	const requests: string[] = [];
	page.on('request', (request) => {
		if (request.method() === 'POST' && request.url().includes('/api/'))
			requests.push(request.url());
	});
	await live(page);
	// The bar is there with the Key bar switch off: live mode is its own switch.
	for (const name of ['Escape', 'Tab', 'Up', 'Control C', 'Enter']) {
		const box = await key(page, name).boundingBox();
		expect(box!.width).toBeGreaterThanOrEqual(44);
	}
	await key(page, 'Tab').click();
	await key(page, 'Up').click();
	await key(page, 'Control C').click();
	await expect.poll(async () => (await fixture(page)).typed).toBe('\t\x1b[A\x03');

	// Typed on the keyboard, then sticky Ctrl and a letter, then Enter on the bar.
	await page.locator('[data-pin]').click();
	await page.keyboard.type('ls');
	await key(page, 'Control').click();
	await expect(key(page, 'Control')).toHaveAttribute('aria-pressed', 'true');
	await page.keyboard.type('a');
	await expect(key(page, 'Control')).toHaveAttribute('aria-pressed', 'false');
	await key(page, 'Enter').click();
	await expect.poll(async () => (await fixture(page)).typed).toBe('\t\x1b[A\x03ls\x01\r');
	await expect(rows(page)).toContainText('ran: ls');

	// Nothing went through the reply routes.
	expect(requests).toEqual([]);
	await page.screenshot({ path: 'test-results/shots/live-keys.png' });
});

test('what the pane prints never types: terminal queries get no answer from the phone', async ({
	page
}) => {
	await live(page);
	// Device attributes, status and cursor reports, colour queries, mode and
	// setting requests, version and window reports. tmux answers these itself;
	// an answer from the phone would arrive in the pane as typed keys.
	const queries = [
		'\x1b[c',
		'\x1b[>c',
		'\x1b[=c',
		'\x1b[5n',
		'\x1b[6n',
		'\x1b[?6n',
		'\x1b]10;?\x07',
		'\x1b]11;?\x1b\\',
		'\x1b]12;?\x07',
		'\x1b]4;1;?\x07',
		'\x1b[?2026$p',
		'\x1b[4$p',
		'\x1bP$qm\x1b\\',
		'\x1bP+q544e\x1b\\',
		'\x1b[>q',
		'\x1b[18t',
		'\x1b[14t',
		'\x1b[?u',
		'\x1b[?1004h'
	].join('');
	await page.request.post(
		`/__fixture/terminal-say?text=${encodeURIComponent(`${queries}queries done\r\n`)}`
	);
	await expect(rows(page)).toContainText('queries done');
	// Focus reporting is on now: taking and losing focus sends nothing either.
	await page.locator('[data-pin]').click();
	await page.getByRole('button', { name: 'Hide keyboard' }).click();
	await page.waitForTimeout(300);
	expect((await fixture(page)).typed).toBe('');
	// The keyboard still types.
	await page.locator('[data-pin]').click();
	await page.keyboard.type('ok');
	await expect.poll(async () => (await fixture(page)).typed).toBe('ok');
});

test('a cut connection says Reconnecting and comes back', async ({ page }) => {
	await live(page);
	// The Mac is gone for a moment: every socket is cut and the next refused.
	await page.request.post('/__fixture/terminal-refuse?code=1013');
	await page.request.post('/__fixture/terminal-drop');
	await expect(chip(page)).toHaveText('Reconnecting');
	await expect(chip(page)).toHaveAttribute('data-live', 'reconnecting');
	// What was on screen stays while it tries.
	await expect(liveView(page)).toBeVisible();
	await page.screenshot({ path: 'test-results/shots/live-reconnecting.png' });

	await page.request.post('/__fixture/terminal-refuse?code=0');
	await expect(chip(page)).toHaveText('Live', { timeout: 15000 });
	await expect(chip(page)).toHaveAttribute('data-live', 'live');
	await expect(rows(page)).toContainText('me@devbox acme-app %');
	await key(page, 'Tab').click();
	await expect.poll(async () => (await fixture(page)).typed).toBe('\t');
});

test('a socket the Mac refuses falls back to the captured view', async ({ page }) => {
	await fresh(page, '/');
	await page.request.post('/__fixture/capability?name=liveTerminal&on=1');
	await page.request.post('/__fixture/terminal-refuse?code=4503');
	await page.goto(threadPath(PANE));
	// The captured view, as it always was.
	await expect(page.locator('.ln').last()).toBeInViewport();
	await expect(chip(page)).toHaveAttribute('aria-pressed', 'false');
	await expect(chip(page)).toHaveText('Live');
	await expect(liveView(page)).toHaveCount(0);
	await expect(page.locator('[data-keybar]')).toHaveCount(0);
	await page.screenshot({ path: 'test-results/shots/live-fallback.png' });

	// The switch on the page asks again.
	await page.request.post('/__fixture/terminal-refuse?code=0');
	await chip(page).click();
	await expect(chip(page)).toHaveAttribute('data-live', 'live');
	await expect(captured(page)).toHaveCount(0);

	// And switches live mode off: the captured view is back, the socket closed.
	await chip(page).click();
	await expect(page.locator('.ln').last()).toBeAttached();
	await expect(liveView(page)).toHaveCount(0);
	await expect.poll(async () => (await fixture(page)).sockets).toBe(0);
});

test('the Mac switching live mode off closes the terminal', async ({ page }) => {
	await live(page);
	await page.request.post('/__fixture/capability?name=liveTerminal&on=0');
	await page.request.post('/__fixture/reset');
	await expect(chip(page)).toHaveCount(0);
	await expect(liveView(page)).toHaveCount(0);
});
