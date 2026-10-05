import { expect, test, type Page } from '@playwright/test';
import { drawer, fakeMic, forget, fresh, pairingLink, reset, TOKEN_HEADER } from './helpers';

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
async function installed(
	page: import('@playwright/test').Page,
	path = '/',
	extra: string[] = []
): Promise<void> {
	await reset(page);
	await page.request.post('/__fixture/capability?name=replies&on=1');
	for (const one of extra)
		await page.request.post(one.startsWith('/') ? one : `/__fixture/capability?name=${one}&on=1`);
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

test('a new build replaces the old one when the app comes to the front', async ({ page }) => {
	await installed(page, '/t/localhost%3A7');
	// The Mac gets a new build while the app is open on the phone.
	await page.request.post('/__fixture/build?tag=2');
	// The app comes to the front: no navigation, nothing closed.
	await page.evaluate(() => document.dispatchEvent(new Event('visibilitychange')));
	await expect.poll(() => build(page), { timeout: 20_000 }).toBe('2');
	// The old build's files are gone from the phone; only the new shell is kept.
	const names = await page.evaluate(() => caches.keys());
	expect(names).toHaveLength(1);
	expect(names[0]).toMatch(/-2$/);
	await expect(page).toHaveURL(/\/t\/localhost(:|%3A)7$/);
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

test('a new build replaces the old one in an app that stays in front', async ({ page }) => {
	await page.clock.install();
	await installed(page, '/t/localhost%3A7');
	await page.request.post('/__fixture/build?tag=6');
	// Nothing brings the app to the front: it was never away. A minute passes.
	await page.clock.fastForward(61_000);
	await expect.poll(() => build(page), { timeout: 20_000 }).toBe('6');
	await expect(page).toHaveURL(/\/t\/localhost(:|%3A)7$/);
});

/** The new worker is in control; the page has not reloaded for it yet. */
async function workerChanged(page: import('@playwright/test').Page, tag: string): Promise<void> {
	await expect
		.poll(() => page.evaluate(() => caches.keys()).catch(() => []), { timeout: 20_000 })
		.toEqual([expect.stringMatching(new RegExp(`-${tag}$`))]);
}

test('a new build waits while a text box holds text that was not sent', async ({ page }) => {
	await installed(page, '/t/localhost%3A7');
	const box = page.getByRole('textbox', { name: 'Reply' });
	await box.tap();
	await page.keyboard.type('still typing');
	await page.request.post('/__fixture/build?tag=3');
	await page.evaluate(() => document.dispatchEvent(new Event('visibilitychange')));
	await workerChanged(page, '3');
	// The keyboard is up: the page is left alone.
	await page.waitForTimeout(1500);
	expect(await build(page)).toBeNull();
	await expect(box).toBeFocused();
	await page.keyboard.type(' this');
	await expect(box).toHaveValue('still typing this');

	// The keyboard goes down, and the text is still not sent: it still waits.
	await box.blur();
	await page.waitForTimeout(6500);
	expect(await build(page)).toBeNull();
	await expect(box).toHaveValue('still typing this');

	// Sent: now it reloads, and nothing was lost.
	await page.getByRole('button', { name: /^Send(ing)?$/ }).tap();
	await expect.poll(() => build(page), { timeout: 20_000 }).toBe('3');
	await expect(box).toHaveValue('');
	await expect(page.locator('.u').last()).toHaveText('still typing this');
});

test('a new build waits for an emptied box too, and reloads when it is empty', async ({ page }) => {
	await installed(page, '/t/localhost%3A7');
	const box = page.getByRole('textbox', { name: 'Reply' });
	await box.fill('never mind');
	await box.blur();
	await page.request.post('/__fixture/build?tag=4');
	await page.evaluate(() => document.dispatchEvent(new Event('visibilitychange')));
	await workerChanged(page, '4');
	await page.waitForTimeout(1500);
	expect(await build(page)).toBeNull();
	await box.fill('');
	await box.blur();
	await expect.poll(() => build(page), { timeout: 20_000 }).toBe('4');
});

test('a new build does not cut a voice turn', async ({ page }) => {
	await fakeMic(page);
	await installed(page, '/', ['voice', '/__fixture/voice?delay=2500']);
	const primary = page.locator('[data-primary]');
	const status = page.locator('[data-voice-status]');
	await expect(primary).toHaveText(/Talk/);
	await primary.click();
	await expect(status).toHaveText('Recording — tap to send');
	await page.evaluate(() => window.__mic.speak(true));

	// A new build lands in the middle of the take.
	await page.request.post('/__fixture/build?tag=5');
	await page.evaluate(() => document.dispatchEvent(new Event('visibilitychange')));
	await workerChanged(page, '5');
	await page.waitForTimeout(1000);
	expect(await build(page)).toBeNull();
	await expect(status).toHaveText('Recording — tap to send');

	// The take is sent; the Mac thinks. Still the same page.
	await page.evaluate(() => window.__mic.speak(false));
	await primary.click();
	await expect(status).toHaveText('Thinking…');
	await page.waitForTimeout(1500);
	expect(await build(page)).toBeNull();
	// The reply is spoken on the page that asked: still no reload while it speaks.
	await expect(status).toHaveText('Speaking…', { timeout: 15_000 });
	expect(await build(page)).toBeNull();
	await expect(page.locator('[data-view="chat"] .a').last()).toContainText('2 threads need you', {
		timeout: 15_000
	});
	expect(await build(page)).toBeNull();

	// The turn is over: the new build comes in.
	await expect.poll(() => build(page), { timeout: 30_000 }).toBe('5');
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

/** The top and bottom edges of an element, in page pixels. */
const edges = (page: Page, selector: string): Promise<{ top: number; bottom: number }> =>
	page.locator(selector).evaluate((el) => {
		const { top, bottom } = el.getBoundingClientRect();
		return { top, bottom };
	});

test('the page ends at the bottom of the screen, with the text box on it', async ({ page }) => {
	await fresh(page);
	await expect(page.locator('[data-compose]')).toBeVisible();
	const height = await page.evaluate(() => window.innerHeight);
	expect(await edges(page, '[data-app]')).toEqual({ top: 0, bottom: height });
	// Under the box there is only its own padding: this browser has no safe area (0px).
	expect((await edges(page, '[data-compose]')).bottom).toBe(height);
	expect(
		await page.locator('[data-compose]').evaluate((el) => getComputedStyle(el).paddingBottom)
	).toBe('10px');
});

test('a Home Screen app laid out one status bar short still fills the screen', async ({ page }) => {
	// What an iPhone does as a Home Screen app with a see-through status bar:
	// the page is laid out 59px shorter than the screen it is drawn on.
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('Emulation.setSafeAreaInsetsOverride', { insets: { top: 59, bottom: 34 } });
	await page.addInitScript(() => {
		const media = window.matchMedia.bind(window);
		window.matchMedia = (query: string): MediaQueryList =>
			query === '(display-mode: standalone)'
				? ({ ...media(query), matches: true } as MediaQueryList)
				: media(query);
		Object.defineProperty(window.screen, 'height', { get: () => window.innerHeight + 59 });
	});
	await fresh(page);
	await expect(page.locator('[data-compose]')).toBeVisible();
	const height = await page.evaluate(() => window.innerHeight);
	// The page reaches the bottom of the screen: no band is left under it.
	await expect.poll(async () => (await edges(page, '[data-app]')).bottom).toBe(height + 59);
	expect((await edges(page, '[data-app]')).top).toBe(0);
	// Under the box: its padding and the home indicator, nothing more.
	expect((await edges(page, '[data-compose]')).bottom).toBe(height + 59);
	expect(
		await page.locator('[data-compose]').evaluate((el) => getComputedStyle(el).paddingBottom)
	).toBe('44px');

	// With the keyboard open the page is exactly what is left above it.
	await page.evaluate(() => {
		const visible = window.visualViewport as VisualViewport;
		Object.defineProperty(visible, 'height', { configurable: true, get: () => 516 });
		visible.dispatchEvent(new Event('resize'));
	});
	await expect(page.locator('[data-app]')).toHaveAttribute('data-kb', '');
	expect(await edges(page, '[data-app]')).toEqual({ top: 0, bottom: 516 });
	expect((await edges(page, '[data-compose]')).bottom).toBe(516);
});

test('a browser tab that is short of the screen is not grown', async ({ page }) => {
	// The same phone in a browser tab: the toolbars take the rest of the screen.
	await page.addInitScript(() => {
		Object.defineProperty(window.screen, 'height', { get: () => window.innerHeight + 59 });
	});
	await fresh(page);
	await expect(page.locator('[data-compose]')).toBeVisible();
	const height = await page.evaluate(() => window.innerHeight);
	expect(await edges(page, '[data-app]')).toEqual({ top: 0, bottom: height });
});
