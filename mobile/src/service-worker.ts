/// <reference types="@sveltejs/kit" />
/// <reference no-default-lib="true"/>
/// <reference lib="esnext" />
/// <reference lib="webworker" />

import { build, files, version } from '$service-worker';
import { parsePush, threadUrl } from './lib/push';

const sw = self as unknown as ServiceWorkerGlobalScope;

const CACHE = `shell-${version}`;
const SHELL = '/index.html';
const ASSETS = new Set([...build, ...files, SHELL]);

/**
 * Tell the open pages something about this worker, for the phone log
 * (`observe.ts`). A worker has no pairing token, so it cannot post a line
 * itself. `version` says which build the worker is from.
 */
async function tell(sev: 'info' | 'warn' | 'error', msg: string, to?: Client): Promise<void> {
	try {
		const pages = to
			? [to]
			: await sw.clients.matchAll({ type: 'window', includeUncontrolled: true });
		const names = await caches.keys();
		for (const page of pages) {
			page.postMessage({
				type: 'log',
				sev,
				msg,
				version,
				cache: CACHE,
				caches: names,
				hello: !!to
			});
		}
	} catch {
		// The log is never what stops a worker.
	}
}

sw.addEventListener('install', (event) => {
	event.waitUntil(
		caches
			.open(CACHE)
			.then((cache) => cache.addAll([...ASSETS]))
			.then(
				() => tell('info', `worker ${version} installed`),
				async (error: unknown) => {
					// The old worker stays, and the phone stays on the old build.
					await tell('error', `worker ${version} did not install: ${String(error)}`);
					throw error;
				}
			)
			.then(() => sw.skipWaiting())
	);
});

sw.addEventListener('activate', (event) => {
	event.waitUntil(
		caches
			.keys()
			.then((keys) =>
				Promise.all(keys.filter((key) => key !== CACHE).map((key) => caches.delete(key)))
			)
			.then(() => sw.clients.claim())
			.then(() => tell('info', `worker ${version} active`))
	);
});

// A page asks which worker serves it, and from which cache.
sw.addEventListener('message', (event) => {
	const data = event.data as { type?: string } | null;
	if (data?.type !== 'log-hello' || !(event.source instanceof Client)) return;
	event.waitUntil(tell('info', `served by worker ${version}`, event.source));
});

sw.addEventListener('fetch', (event) => {
	const { request } = event;
	if (request.method !== 'GET') return;
	const url = new URL(request.url);
	if (url.origin !== sw.location.origin) return;
	// Live data always goes to the network and is never stored here.
	if (url.pathname.startsWith('/api/')) return;

	if (ASSETS.has(url.pathname)) {
		event.respondWith(cached(url.pathname, request));
		return;
	}
	if (request.mode === 'navigate') {
		event.respondWith(cached(SHELL, request));
	}
});

// A push from the Mac: always a notification, even for a message that cannot
// be read. iOS takes push away from an app that gets one and shows nothing.
sw.addEventListener('push', (event) => {
	let text: string | null = null;
	try {
		text = event.data?.text() ?? null;
	} catch {
		// Shown as the generic notification.
	}
	const message = parsePush(text);
	event.waitUntil(
		sw.registration.showNotification(message.title, {
			body: message.body,
			tag: message.tag,
			icon: '/icon-192.png',
			data: { thread: message.thread }
		})
	);
});

sw.addEventListener('notificationclick', (event) => {
	event.notification.close();
	const thread = (event.notification.data as { thread?: unknown } | null)?.thread;
	event.waitUntil(open(threadUrl(typeof thread === 'string' ? thread : '')));
});

/** Show `url` in the app: in the window that is open, or in a new one. */
async function open(url: string): Promise<void> {
	const windows = await sw.clients.matchAll({ type: 'window', includeUncontrolled: true });
	const client = windows[0];
	if (!client) {
		await sw.clients.openWindow(url);
		return;
	}
	client.postMessage({ type: 'open', url });
	try {
		await client.focus();
	} catch {
		// The window has the address already; it only stays behind.
	}
}

async function cached(key: string, request: Request): Promise<Response> {
	const cache = await caches.open(CACHE);
	const hit = await cache.match(key);
	if (hit) return hit;
	// The cache lost a file it was installed with: the page gets the Mac's.
	void tell('warn', `not in ${CACHE}, read from the Mac: ${key}`);
	return fetch(request);
}
