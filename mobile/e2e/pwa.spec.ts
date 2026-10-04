import { expect, test } from '@playwright/test';
import { drawer, forget, fresh, pairingLink, reset, TOKEN_HEADER } from './helpers';

test('cached lists paint before the network answers', async ({ page }) => {
	await fresh(page);
	await page.getByRole('button', { name: 'Menu' }).click();
	await expect(drawer(page).getByText('checkout-fix')).toBeVisible();

	// Second visit: the server is slow. The lists must already be there.
	let release: () => void = () => {};
	const held = new Promise<void>((done) => (release = done));
	await page.route('**/api/**', async (route) => {
		await held;
		await route.continue();
	});
	await page.reload();
	await expect(page.locator('.chip').first()).toHaveText('2 need you');
	await page.getByRole('button', { name: 'Menu' }).click();
	await expect(drawer(page).getByText('checkout-fix')).toBeVisible();
	await expect(drawer(page).locator('[data-host="devbox"]')).toBeVisible();
	await expect(page.locator('.skel')).toHaveCount(0);
	release();
});

test('first visit shows skeleton rows, not a spinner, until data lands', async ({ page }) => {
	await reset(page);
	let release: () => void = () => {};
	const held = new Promise<void>((done) => (release = done));
	await page.route('**/api/**', async (route) => {
		await held;
		await route.continue();
	});
	await forget(page);
	await page.goto(pairingLink());
	await page.getByRole('button', { name: 'Menu' }).click();
	await expect(drawer(page).locator('.skrow')).toHaveCount(6);
	release();
	await expect(drawer(page).getByText('checkout-fix')).toBeVisible();
	await expect(drawer(page).locator('.skrow')).toHaveCount(0);
});

test('the service worker caches the shell and never the API', async ({ page }) => {
	await fresh(page);
	await page.evaluate(() => navigator.serviceWorker.ready);
	await page.reload();
	await expect
		.poll(() => page.evaluate(() => Boolean(navigator.serviceWorker.controller)))
		.toBe(true);

	const cached = await page.evaluate(async () => {
		const urls: string[] = [];
		for (const name of await caches.keys()) {
			for (const request of await (await caches.open(name)).keys()) {
				urls.push(new URL(request.url).pathname);
			}
		}
		return urls;
	});
	expect(cached).toContain('/index.html');
	expect(cached.some((path) => path.startsWith('/_app/immutable/'))).toBe(true);
	expect(cached.filter((path) => path.startsWith('/api/'))).toEqual([]);

	// With the worker in control, an API read still sees the server's newest state.
	const count = (): Promise<number> =>
		page.evaluate(async (headers) => {
			const body = (await (await fetch('/api/threads', { headers })).json()) as {
				threads: { status: string }[];
			};
			return body.threads.filter((thread) => thread.status === 'waiting').length;
		}, TOKEN_HEADER);
	expect(await count()).toBe(2);
	await page.request.post('/__fixture/wait?id=localhost:3');
	expect(await count()).toBe(3);
	const after = await page.evaluate(async () => {
		const names = await caches.keys();
		const hits = await Promise.all(
			names.map(async (n) => (await caches.open(n)).match('/api/threads'))
		);
		return hits.filter(Boolean).length;
	});
	expect(after).toBe(0);
});

test('the shell opens with the server unreachable', async ({ page, context }) => {
	await fresh(page);
	await page.evaluate(() => navigator.serviceWorker.ready);
	await page.reload();
	await expect
		.poll(() => page.evaluate(() => Boolean(navigator.serviceWorker.controller)))
		.toBe(true);
	await context.setOffline(true);
	await page.reload();
	await expect(page.locator('.chip').first()).toHaveText('2 need you');
	await context.setOffline(false);
});

test('a refused device sees "Not allowed"; a switched-off feature does not', async ({ page }) => {
	await fresh(page);
	// A feature that is off answers 403 "disabled". That is not a refusal.
	const disabled = await page.evaluate(
		async (headers) => (await fetch('/api/voice', { headers })).status,
		TOKEN_HEADER
	);
	expect(disabled).toBe(403);
	await page.getByRole('button', { name: 'Menu' }).click();
	const refresh = drawer(page).getByRole('button', { name: 'Refresh' });
	await refresh.click();
	await expect(refresh).toBeEnabled();
	await expect(page.getByRole('alert')).toHaveCount(0);
	await expect(drawer(page).getByText('checkout-fix')).toBeVisible();

	await page.request.post('/__fixture/deny?on=1');
	await refresh.click();
	await expect(page.getByRole('alert')).toHaveText('Not allowed');
	await expect(drawer(page)).toHaveCount(0);
});

test('manifest and icons are served for Add to Home Screen', async ({ page }) => {
	const manifest = await (await page.request.get('/manifest.webmanifest')).json();
	expect(manifest.display).toBe('standalone');
	expect(manifest.start_url).toBe('/');
	for (const icon of manifest.icons) expect((await page.request.get(icon.src)).ok()).toBe(true);
	await page.goto('/');
	await expect(page.locator('link[rel="apple-touch-icon"]')).toHaveAttribute(
		'href',
		/\/icon-180\.png$/
	);
});

test('reduced motion: no slide and no pulse', async ({ page }) => {
	await page.emulateMedia({ reducedMotion: 'reduce' });
	await fresh(page);
	await page.getByRole('button', { name: 'Menu' }).click();
	const styles = await page.evaluate(() => ({
		drawer: getComputedStyle(document.querySelector('[data-drawer]')!).transitionDuration,
		dot: getComputedStyle(document.querySelector('.dot.waiting')!).animationName
	}));
	expect(styles.drawer).toMatch(/^0s/);
	expect(styles.dot).toBe('none');
});

/** Which build the page runs: the fixture marks the shell of a newer one. */
const build = (page: import('@playwright/test').Page): Promise<string | null> =>
	page
		.evaluate(
			() => document.querySelector('meta[name="mm-build"]')?.getAttribute('content') ?? null
		)
		// The page is reloading under the question: ask again.
		.catch(() => null);

/** The app with its worker in control, long enough for the worker's own update check to be over. */
async function installed(page: import('@playwright/test').Page, path = '/'): Promise<void> {
	await reset(page);
	await page.request.post('/__fixture/capability?name=replies&on=1');
	await forget(page);
	await page.goto(pairingLink(path));
	await page.evaluate(() => navigator.serviceWorker.ready);
	await page.reload();
	await expect
		.poll(() => page.evaluate(() => Boolean(navigator.serviceWorker.controller)))
		.toBe(true);
	await page.waitForTimeout(3000);
	expect(await build(page)).toBeNull();
}

test('a new build replaces the old one when the app comes to the front, and the draft is kept', async ({
	page
}) => {
	await installed(page, '/t/localhost%3A7');
	const box = page.getByRole('textbox', { name: 'Reply' });
	await box.fill('half a thought\nand a second line');
	await box.blur();

	// The Mac gets a new build while the app is open on the phone.
	await page.request.post('/__fixture/build?tag=2');
	// The app comes to the front: no navigation, nothing closed.
	await page.evaluate(() => document.dispatchEvent(new Event('visibilitychange')));
	await expect.poll(() => build(page), { timeout: 20_000 }).toBe('2');
	// The old build's files are gone from the phone; only the new shell is kept.
	const names = await page.evaluate(() => caches.keys());
	expect(names).toHaveLength(1);
	expect(names[0]).toMatch(/-2$/);
	// Same thread, same text, nothing cleared by hand.
	await expect(page).toHaveURL(/\/t\/localhost(:|%3A)7$/);
	await expect(box).toHaveValue('half a thought\nand a second line');
	// The API is still not in any cache.
	const api = await page.evaluate(async () => {
		const found: string[] = [];
		for (const name of await caches.keys())
			for (const request of await (await caches.open(name)).keys())
				if (new URL(request.url).pathname.startsWith('/api/')) found.push(request.url);
		return found;
	});
	expect(api).toEqual([]);
});

test('a new build waits for the fingers to leave the text box', async ({ page }) => {
	await installed(page, '/t/localhost%3A7');
	const box = page.getByRole('textbox', { name: 'Reply' });
	await box.tap();
	await page.keyboard.type('still typing');
	await page.request.post('/__fixture/build?tag=3');
	await page.evaluate(() => document.dispatchEvent(new Event('visibilitychange')));
	// The new worker takes over, and the page is left alone while the keyboard is up.
	await expect
		.poll(() => page.evaluate(() => caches.keys()).catch(() => []), { timeout: 20_000 })
		.toEqual([expect.stringMatching(/-3$/)]);
	await page.waitForTimeout(1500);
	expect(await build(page)).toBeNull();
	await expect(box).toBeFocused();
	await page.keyboard.type(' this');
	await expect(box).toHaveValue('still typing this');

	// The keyboard goes down: now it reloads, with the text kept.
	await box.blur();
	await expect.poll(() => build(page), { timeout: 20_000 }).toBe('3');
	await expect(box).toHaveValue('still typing this');
});

test('a first visit is not reloaded when its first worker takes over', async ({ page }) => {
	await reset(page);
	await forget(page);
	let loads = 0;
	page.on('load', () => (loads += 1));
	await page.goto(pairingLink());
	await page.evaluate(() => navigator.serviceWorker.ready);
	await expect
		.poll(() => page.evaluate(() => Boolean(navigator.serviceWorker.controller)))
		.toBe(true);
	await page.waitForTimeout(1500);
	expect(loads).toBe(1);
});
