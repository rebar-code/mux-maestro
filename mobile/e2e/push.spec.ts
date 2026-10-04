import { mkdirSync } from 'node:fs';
import { expect, test, type BrowserContext, type Page, type Worker } from '@playwright/test';
import { drawer, forget, pairingLink, reset, threadPath } from './helpers';

// The headless shell refuses every notification. The full browser shows them.
test.use({ channel: 'chromium' });

const THREAD = 'localhost:3';
const ENDPOINT = 'https://web.push.apple.com/QDemoPhone';

declare global {
	interface Window {
		__push: { asked: number; key: number[]; userVisibleOnly: boolean | null };
		/** Content-Security-Policy violations the page reported. */
		__csp: string[];
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

test('the switch follows the Mac while the app is open, with no reload', async ({ page }) => {
	await open(page, { standalone: true, answer: 'granted' }, threadPath(THREAD));
	await expect(page.locator('.tbar .title b')).toBeVisible();
	await openDrawer(page);
	await toggle(page).click();
	await expect(toggle(page)).toHaveAttribute('aria-checked', 'true');
	await expect.poll(async () => (await held(page)).focus[ENDPOINT]).toBe(THREAD);

	// The Mac turns notifications off and drops its phones. The app stays open.
	await page.request.post('/__fixture/capability?name=notifications&on=0');
	await expect(row(page)).toHaveCount(0);
	await page.request.post('/__fixture/push-forget');
	expect((await held(page)).subscriptions).toEqual([]);

	// On again: the phone hands its subscription back and says what it shows.
	await page.request.post('/__fixture/capability?name=notifications&on=1');
	await expect(toggle(page)).toHaveAttribute('aria-checked', 'true');
	expect((await held(page)).subscriptions).toHaveLength(1);
	await expect.poll(async () => (await held(page)).focus[ENDPOINT]).toBe(THREAD);
});

test('when the Mac has dropped the phone, the switch stops saying on', async ({ page }) => {
	await open(page, { standalone: true, answer: 'granted' });
	await openDrawer(page);
	await toggle(page).click();
	await expect(toggle(page)).toHaveAttribute('aria-checked', 'true');

	// The Mac drops its phones and has no room to take this one back.
	await page.request.post('/__fixture/push-forget');
	await page.request.post('/__fixture/push-limit?on=1');
	// The next "this thread is on screen" call is answered 404.
	await drawer(page).locator(`a[href="/t/${THREAD}"]`).click();
	await page.getByRole('button', { name: 'Menu' }).click();
	await expect(toggle(page)).toHaveAttribute('aria-checked', 'false');
	expect((await held(page)).subscriptions).toEqual([]);

	// With room again, a dropped phone hands its subscription back by itself.
	await page.request.post('/__fixture/push-limit?on=0');
	await toggle(page).click();
	await expect(toggle(page)).toHaveAttribute('aria-checked', 'true');
	await page.request.post('/__fixture/push-forget');
	await drawer(page).getByText('Manager').click();
	await expect.poll(async () => (await held(page)).subscriptions.length).toBe(1);
	await page.getByRole('button', { name: 'Menu' }).click();
	await expect(toggle(page)).toHaveAttribute('aria-checked', 'true');
});

test('a phone that gets its first config after the app started still shows the switch on', async ({
	page
}) => {
	await reset(page);
	await page.request.post('/__fixture/capability?name=notifications&on=1');
	await forget(page);
	// The phone holds a subscription made with the Mac's key, and no cached config.
	await page.evaluate(() => {
		const text = atob(
			'BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8'
				.replace(/-/g, '+')
				.replace(/_/g, '/')
		);
		sessionStorage.clear();
		sessionStorage.setItem('e2e.permission', 'granted');
		sessionStorage.setItem('e2e.key', JSON.stringify([...text].map((char) => char.charCodeAt(0))));
	});
	await fakePush(page, { standalone: true, answer: 'granted' });
	let release: () => void = () => {};
	const gate = new Promise<void>((done) => (release = done));
	await page.route('**/api/**', async (route) => {
		await gate;
		await route.continue();
	});
	await page.goto(pairingLink());
	// The app has started and read the phone's state; the Mac has said nothing yet.
	await page.evaluate(() => navigator.serviceWorker.ready);
	await page.waitForTimeout(500);
	expect((await held(page)).subscriptions).toEqual([]);
	release();
	await openDrawer(page);
	await expect(toggle(page)).toHaveAttribute('aria-checked', 'true');
	expect((await held(page)).subscriptions).toHaveLength(1);
});

interface Shown {
	title: string;
	body: string;
	tag: string;
}

/** The real service worker of a paired app, active, with notifications allowed. */
async function startWorker(page: Page, context: BrowserContext): Promise<Worker> {
	await context.grantPermissions(['notifications']);
	await reset(page);
	await forget(page);
	// Every policy violation the page reports, for the check at the end.
	await page.addInitScript(() => {
		window.__csp = [];
		document.addEventListener('securitypolicyviolation', (event) => {
			window.__csp.push(`${event.violatedDirective} ${event.blockedURI}`);
		});
	});
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
	await worker.evaluate(() => {
		const scope = self as unknown as { __csp: string[] };
		scope.__csp = [];
		self.addEventListener('securitypolicyviolation', (event) => {
			const violation = event as SecurityPolicyViolationEvent;
			scope.__csp.push(`${violation.violatedDirective} ${violation.blockedURI}`);
		});
	});
	return worker;
}

const shown = (worker: Worker): Promise<Shown[]> =>
	worker.evaluate(async () => {
		const scope = self as unknown as ServiceWorkerGlobalScope;
		return (await scope.registration.getNotifications()).map((n) => ({
			title: n.title,
			body: n.body,
			tag: n.tag
		}));
	});

/**
 * Deliver a push to the worker the way the browser does: through the
 * debugging protocol, so the worker gets a real (trusted) `push` event, not
 * one the test made itself.
 */
async function pushed(page: Page, data: string): Promise<void> {
	const cdp = await page.context().newCDPSession(page);
	const found = new Promise<string>((done) => {
		cdp.on('ServiceWorker.workerRegistrationUpdated', (event) => {
			const registration = event.registrations.find((r) => !r.isDeleted);
			if (registration) done(registration.registrationId);
		});
	});
	await cdp.send('ServiceWorker.enable');
	await cdp.send('ServiceWorker.deliverPushMessage', {
		origin: ORIGIN(page),
		registrationId: await found,
		data
	});
	await cdp.detach();
}

const ORIGIN = (page: Page): string =>
	new URL(page.context().serviceWorkers()[0]?.url() ?? page.url()).origin;

/**
 * Push `data` until the notifications are `expected`. The browser hands each
 * notification to the system's notification centre, which was seen to drop the
 * first one of a run. A message sent twice has one tag, so it still shows once.
 */
async function pushUntil(
	page: Page,
	worker: Worker,
	data: string,
	expected: Shown[]
): Promise<void> {
	await expect(async () => {
		await pushed(page, data);
		await expect.poll(() => shown(worker), { timeout: 1500 }).toEqual(expected);
	}).toPass({ timeout: 15_000 });
}

const WAITING = JSON.stringify({
	v: 1,
	kind: 'waiting',
	thread: THREAD,
	tag: 'demo-tag',
	title: 'MuxMaestro',
	body: 'A thread needs you'
});

const tapped = (worker: Worker, tag: string): Promise<void> =>
	worker.evaluate(async (tag) => {
		const scope = self as unknown as ServiceWorkerGlobalScope;
		const [notification] = await scope.registration.getNotifications({ tag });
		self.dispatchEvent(new NotificationEvent('notificationclick', { notification }));
	}, tag);

const threadAddress = new RegExp(`${threadPath(THREAD).replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`);

test('a push shows a notification, and a tap on it opens that thread', async ({
	page,
	context
}) => {
	const worker = await startWorker(page, context);
	// The app shell is served under the strict policy; the check below means something.
	const policy = (await page.request.get('/')).headers()['content-security-policy'] ?? '';
	expect(policy).toContain("script-src 'self'");
	expect(policy).not.toContain("'unsafe-eval'");

	await worker.evaluate(() => {
		const scope = self as unknown as { __trusted: boolean[] };
		scope.__trusted = [];
		self.addEventListener('push', (event) => scope.__trusted.push(event.isTrusted));
	});
	await pushUntil(page, worker, WAITING, [
		{ title: 'MuxMaestro', body: 'A thread needs you', tag: 'demo-tag' }
	]);
	expect(
		await worker.evaluate(() => (self as unknown as { __trusted: boolean[] }).__trusted)
	).not.toContain(false);
	// A second message for the thread replaces the first.
	await pushUntil(
		page,
		worker,
		JSON.stringify({
			thread: THREAD,
			tag: 'demo-tag',
			title: 'MuxMaestro',
			body: 'A thread finished'
		}),
		[{ title: 'MuxMaestro', body: 'A thread finished', tag: 'demo-tag' }]
	);
	// A message that cannot be read still shows something.
	await pushed(page, 'not json');
	await expect.poll(async () => (await shown(worker)).length).toBe(2);

	await tapped(worker, 'demo-tag');
	await expect(page).toHaveURL(threadAddress);
	await expect(page.locator('.tbar .title b')).toBeVisible();
	await expect.poll(async () => (await shown(worker)).map((n) => n.tag)).toEqual(['muxmaestro']);

	// Push, notification and tap ran under the policy with nothing blocked.
	expect(await page.evaluate(() => window.__csp)).toEqual([]);
	expect(await worker.evaluate(() => (self as unknown as { __csp: string[] }).__csp)).toEqual([]);
});

test('with no window open, a tap on the notification opens the thread in a new one', async ({
	page,
	context
}) => {
	const worker = await startWorker(page, context);
	await pushUntil(page, worker, WAITING, [
		{ title: 'MuxMaestro', body: 'A thread needs you', tag: 'demo-tag' }
	]);
	// The app is closed; only the service worker is left.
	await page.goto('about:blank');
	await expect
		.poll(() =>
			worker.evaluate(
				async () =>
					(
						await (self as unknown as ServiceWorkerGlobalScope).clients.matchAll({
							type: 'window',
							includeUncontrolled: true
						})
					).length
			)
		)
		.toBe(0);

	// The worker's own code runs to the browser's real `openWindow`, which is
	// only watched here, not replaced. A browser opens a window only for a
	// real tap on a notification, and no test can make one: the real call
	// answers "not allowed". A wrong address would be a TypeError before that.
	await worker.evaluate(() => {
		const scope = self as unknown as ServiceWorkerGlobalScope & {
			__opened: { url: string; answer: string }[];
		};
		scope.__opened = [];
		const real = scope.clients.openWindow.bind(scope.clients);
		scope.clients.openWindow = async (url) => {
			const call = { url: String(url), answer: 'pending' };
			scope.__opened.push(call);
			try {
				const client = await real(url);
				call.answer = 'opened';
				return client;
			} catch (error) {
				call.answer = (error as Error).name;
				throw error;
			}
		};
	});
	await tapped(worker, 'demo-tag');
	const opened = (): Promise<{ url: string; answer: string }[]> =>
		worker.evaluate(
			() => (self as unknown as { __opened: { url: string; answer: string }[] }).__opened
		);
	await expect
		.poll(opened)
		.toEqual([
			{ url: threadPath(THREAD), answer: expect.stringMatching(/^(opened|InvalidAccessError)$/) }
		]);
	await expect.poll(async () => (await shown(worker)).length).toBe(0);

	// The address is one the app shell answers from a cold start.
	const cold = await context.newPage();
	await cold.goto((await opened())[0].url);
	await expect(cold).toHaveURL(threadAddress);
	await expect(cold.locator('.tbar .title b')).toBeVisible();
});
