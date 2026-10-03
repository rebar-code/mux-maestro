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
