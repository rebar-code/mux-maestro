import { mkdirSync } from 'node:fs';
import { expect, test, type Page } from '@playwright/test';
import { drawer, forget, pairingLink, reset, threadPath } from './helpers';

// The headless shell refuses every notification. The full browser shows them.
test.use({ channel: 'chromium' });

const THREAD = 'localhost:3';
const ENDPOINT = 'https://web.push.apple.com/QDemoPhone';

declare global {
	interface Window {
		__push: { asked: number; key: number[]; userVisibleOnly: boolean | null };
	}
}

interface FakePhone {
	/** The app was opened from the Home Screen. */
	standalone: boolean;
	/** What the permission question answers. */
	answer: NotificationPermission;
}

/**
 * Give the page a push service the test controls. The service worker is the
 * real one; only the permission question and the subscription are faked, and
 * both are kept for the tab, as a browser keeps them.
 */
async function fakePush(page: Page, phone: FakePhone): Promise<void> {
	await page.addInitScript(
		({ phone, endpoint }) => {
			const read = (key: string): string | null => sessionStorage.getItem(key);
			window.__push = { asked: 0, key: [], userVisibleOnly: null };
			Object.defineProperty(navigator, 'standalone', { get: () => phone.standalone });
			Object.defineProperty(Notification, 'permission', {
				get: () => read('e2e.permission') ?? 'default'
			});
			Notification.requestPermission = async () => {
				window.__push.asked += 1;
				sessionStorage.setItem('e2e.permission', phone.answer);
				return phone.answer;
			};
			const held = (): PushSubscription | null => {
				const key = read('e2e.key');
				if (!key) return null;
				return {
					endpoint,
					options: { applicationServerKey: new Uint8Array(JSON.parse(key) as number[]).buffer },
					toJSON: () => ({ endpoint, keys: { p256dh: 'BDemoKey', auth: 'DemoAuthSecret' } }),
					unsubscribe: async () => {
						sessionStorage.removeItem('e2e.key');
						return true;
					}
				} as unknown as PushSubscription;
			};
			PushManager.prototype.getSubscription = async () => held();
			PushManager.prototype.subscribe = async (options) => {
				const key = [...new Uint8Array(options?.applicationServerKey as ArrayBuffer)];
				window.__push.key = key;
				window.__push.userVisibleOnly = options?.userVisibleOnly ?? null;
				sessionStorage.setItem('e2e.key', JSON.stringify(key));
				return held() as PushSubscription;
			};
		},
		{ phone, endpoint: ENDPOINT }
	);
}

async function open(page: Page, phone: FakePhone, path = '/'): Promise<void> {
	await reset(page);
	await page.request.post('/__fixture/capability?name=notifications&on=1');
	await forget(page);
	await page.evaluate(() => sessionStorage.clear());
	await fakePush(page, phone);
	await page.goto(pairingLink(path));
}

async function openDrawer(page: Page): Promise<void> {
	await page.getByRole('button', { name: 'Menu' }).click();
	await row(page).scrollIntoViewIfNeeded();
}

const row = (page: Page) => drawer(page).locator('[data-push]');
const toggle = (page: Page) => row(page).getByRole('switch', { name: 'Notifications' });

interface Held {
	subscriptions: { endpoint: string; keys: { p256dh: string; auth: string } }[];
	focus: Record<string, string | null>;
}

async function held(page: Page): Promise<Held> {
	return (await (await page.request.post('/__fixture/push')).json()) as Held;
}

/** Screenshots are taken only when SHOTS names a directory outside the repo. */
async function shot(page: Page, name: string): Promise<void> {
	const dir = process.env.SHOTS;
	if (!dir) return;
	mkdirSync(dir, { recursive: true });
	await page.waitForTimeout(250);
	await page.screenshot({ path: `${dir}/${name}.png` });
}

test('the control is not there while the Mac has notifications off', async ({ page }) => {
	await open(page, { standalone: true, answer: 'granted' });
	await openDrawer(page);
	await expect(row(page)).toBeVisible();
	await page.request.post('/__fixture/capability?name=notifications&on=0');
	await drawer(page).getByRole('button', { name: 'Refresh' }).click();
	await expect(row(page)).toHaveCount(0);
});

test('in a browser tab on iOS it says to add the app to the Home Screen', async ({ page }) => {
	await open(page, { standalone: false, answer: 'granted' });
	await openDrawer(page);
	await expect(row(page)).toHaveAttribute('data-push', 'install');
	await expect(row(page)).toContainText('Add this app to the Home Screen first');
	await expect(toggle(page)).toHaveCount(0);
	expect(await page.evaluate(() => window.__push.asked)).toBe(0);
	await shot(page, 'push-not-installed');
});

test('a tap asks for permission, subscribes with the Mac key, and tells the Mac', async ({
	page
}) => {
	await open(page, { standalone: true, answer: 'granted' });
	await openDrawer(page);
	await expect(toggle(page)).toHaveAttribute('aria-checked', 'false');
	// Nothing is asked until the tap.
	expect(await page.evaluate(() => window.__push.asked)).toBe(0);
	const box = await toggle(page).boundingBox();
	expect(box!.height).toBeGreaterThanOrEqual(44);
	expect(box!.width).toBeGreaterThanOrEqual(44);
	await shot(page, 'push-off');

	await toggle(page).click();
	await expect(toggle(page)).toHaveAttribute('aria-checked', 'true');
	const asked = await page.evaluate(() => window.__push);
	expect(asked.asked).toBe(1);
	expect(asked.userVisibleOnly).toBe(true);
	// The Mac's key: an uncompressed P-256 point.
	expect(asked.key).toHaveLength(65);
	expect(asked.key[0]).toBe(4);
	expect((await held(page)).subscriptions).toEqual([
		{ endpoint: ENDPOINT, keys: { p256dh: 'BDemoKey', auth: 'DemoAuthSecret' } }
	]);
	await shot(page, 'push-on');

	// It is still on after a reload, and the Mac holds one subscription, not two.
	await page.reload();
	await openDrawer(page);
	await expect(toggle(page)).toHaveAttribute('aria-checked', 'true');
	expect((await held(page)).subscriptions).toHaveLength(1);

	// Off again: the Mac forgets the phone.
	await toggle(page).click();
	await expect(toggle(page)).toHaveAttribute('aria-checked', 'false');
	expect((await held(page)).subscriptions).toEqual([]);
	expect(await page.evaluate(() => sessionStorage.getItem('e2e.key'))).toBeNull();
});

test('a refused permission shows as blocked and subscribes nothing', async ({ page }) => {
	await open(page, { standalone: true, answer: 'denied' });
	await openDrawer(page);
	await toggle(page).click();
	await expect(row(page)).toHaveAttribute('data-push', 'denied');
	await expect(row(page)).toContainText('Blocked');
	await expect(toggle(page)).toHaveCount(0);
	expect((await held(page)).subscriptions).toEqual([]);
	await shot(page, 'push-denied');
});

test('a subscription the Mac refuses is not kept on the phone', async ({ page }) => {
	await open(page, { standalone: true, answer: 'granted' });
	await page.request.post('/__fixture/push-limit?on=1');
	await openDrawer(page);
	await toggle(page).click();
	await expect(row(page).getByRole('status')).toHaveText('Failed');
	await expect(toggle(page)).toHaveAttribute('aria-checked', 'false');
	expect(await page.evaluate(() => sessionStorage.getItem('e2e.key'))).toBeNull();
	await shot(page, 'push-failed');
});

test('an open thread tells the Mac it is on screen, and says so when it is left', async ({
	page
}) => {
	await open(page, { standalone: true, answer: 'granted' });
	await openDrawer(page);
	await toggle(page).click();
	await expect(toggle(page)).toHaveAttribute('aria-checked', 'true');

	await drawer(page).locator(`a[href="/t/${THREAD}"]`).click();
	await expect.poll(async () => (await held(page)).focus[ENDPOINT]).toBe(THREAD);
	await page.getByRole('button', { name: 'Menu' }).click();
	await drawer(page).getByText('Manager').click();
	await expect.poll(async () => (await held(page)).focus[ENDPOINT]).toBeNull();
});

test('a push shows a notification, and a tap on it opens that thread', async ({
	page,
	context
}) => {
	await context.grantPermissions(['notifications']);
	await reset(page);
	await forget(page);
	await page.goto(pairingLink());
	await page.evaluate(() => navigator.serviceWorker.ready);
	const worker = context.serviceWorkers()[0] ?? (await context.waitForEvent('serviceworker'));
	// A worker that is still installing cannot show a notification.
	await expect
		.poll(() =>
			worker.evaluate(
				() => (self as unknown as ServiceWorkerGlobalScope).registration.active?.state
			)
		)
		.toBe('activated');

	const shown = (): Promise<{ title: string; body: string; tag: string }[]> =>
		worker.evaluate(async () => {
			const scope = self as unknown as ServiceWorkerGlobalScope;
			return (await scope.registration.getNotifications()).map((n) => ({
				title: n.title,
				body: n.body,
				tag: n.tag
			}));
		});
	const pushed = (data: string): Promise<void> =>
		worker.evaluate((data) => {
			self.dispatchEvent(new PushEvent('push', { data }));
		}, data);

	await pushed(
		JSON.stringify({
			v: 1,
			kind: 'waiting',
			thread: THREAD,
			tag: 'demo-tag',
			title: 'MuxMaestro',
			body: 'A thread needs you'
		})
	);
	await expect
		.poll(shown)
		.toEqual([{ title: 'MuxMaestro', body: 'A thread needs you', tag: 'demo-tag' }]);
	// A second message for the thread replaces the first.
	await pushed(
		JSON.stringify({
			thread: THREAD,
			tag: 'demo-tag',
			title: 'MuxMaestro',
			body: 'A thread finished'
		})
	);
	await expect
		.poll(shown)
		.toEqual([{ title: 'MuxMaestro', body: 'A thread finished', tag: 'demo-tag' }]);
	// A message that cannot be read still shows something.
	await pushed('not json');
	await expect.poll(async () => (await shown()).length).toBe(2);

	await worker.evaluate(async () => {
		const scope = self as unknown as ServiceWorkerGlobalScope;
		const [notification] = await scope.registration.getNotifications({ tag: 'demo-tag' });
		self.dispatchEvent(new NotificationEvent('notificationclick', { notification }));
	});
	await expect(page).toHaveURL(
		new RegExp(`${threadPath(THREAD).replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`)
	);
	await expect(page.locator('.tbar .title b')).toBeVisible();
	await expect.poll(async () => (await shown()).map((n) => n.tag)).toEqual(['muxmaestro']);
});
