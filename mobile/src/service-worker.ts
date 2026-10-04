/// <reference types="@sveltejs/kit" />
/// <reference no-default-lib="true"/>
/// <reference lib="esnext" />
/// <reference lib="webworker" />

import { build, files, version } from '$service-worker';

const sw = self as unknown as ServiceWorkerGlobalScope;

const CACHE = `shell-${version}`;
const SHELL = '/index.html';
const ASSETS = new Set([...build, ...files, SHELL]);

sw.addEventListener('install', (event) => {
	event.waitUntil(
		caches
			.open(CACHE)
			.then((cache) => cache.addAll([...ASSETS]))
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
	);
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

async function cached(key: string, request: Request): Promise<Response> {
	const cache = await caches.open(CACHE);
	return (await cache.match(key)) ?? fetch(request);
}
