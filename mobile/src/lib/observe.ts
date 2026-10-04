import { version } from '$app/environment';
import { postLog } from './api';
import { live } from './live.svelte';
import {
	attach,
	Batcher,
	describeError,
	iosVersion,
	pathOf,
	record,
	statusSeverity,
	threadIn,
	type Fields,
	type Line,
	type Severity
} from './phonelog';

// The part of the phone log that listens to the page: errors, failed
// requests, the service worker, the app coming and going. Every line goes to
// the Mac with the build this page runs, so "is the phone on the new build"
// is read from the log and not asked of the human.

const LOG_PATH = '/api/log';

let started = false;

/**
 * Start the phone log. Called once, before the app draws, so an error while
 * it starts is in the log too.
 */
export function observe(): void {
	if (started) return;
	started = true;
	// One page load is one session: its lines share this, and the device is
	// described once, in the first of them.
	const sid = Math.random().toString(36).slice(2, 10);
	const batcher = new Batcher({
		send: (lines, last) => postLog({ sid, build: version, lines }, last)
	});
	attach((line) => batcher.push(placed(line)));
	record('info', 'session', 'app loaded', device());
	watchErrors();
	watchFetch();
	watchLife(batcher);
	watchWorker();
}

/**
 * The line with its project: the tmux session of the thread it is about, or
 * of the thread on screen. A line about no thread has none.
 */
function placed(line: Line): Line {
	const named = line.fields.thread;
	const id = typeof named === 'string' ? named : threadIn(location.pathname);
	const thread = id ? live.byId(id) : undefined;
	if (!thread) return line;
	return { ...line, fields: { ...line.fields, project: thread.session, host: thread.host } };
}

function device(): Fields {
	const navigation = performance.getEntriesByType('navigation')[0] as
		PerformanceNavigationTiming | undefined;
	const connection = (navigator as { connection?: { effectiveType?: string } }).connection;
	return {
		ios: iosVersion(navigator.userAgent),
		ua: navigator.userAgent,
		standalone:
			matchMedia('(display-mode: standalone)').matches ||
			(navigator as { standalone?: boolean }).standalone === true,
		viewport: `${innerWidth}x${innerHeight}@${devicePixelRatio}`,
		net: connection?.effectiveType ?? (navigator.onLine ? 'online' : 'offline'),
		nav: navigation?.type
	};
}

const here = (url: string): string => pathOf(url, location.href);

function watchErrors(): void {
	// In the capture phase: a file that fails to load does not bubble.
	window.addEventListener(
		'error',
		(event: Event) => {
			if (event instanceof ErrorEvent) {
				const { msg, ...rest } = describeError(event.error ?? event.message, location.origin);
				record('error', 'error', msg, {
					...rest,
					src: event.filename ? here(event.filename) : undefined,
					line: event.lineno,
					col: event.colno
				});
				return;
			}
			const target = event.target;
			if (!(target instanceof HTMLElement)) return;
			const src = target.getAttribute('src') ?? target.getAttribute('href');
			record('error', 'resource', `<${target.localName}> did not load`, {
				src: src ? here(src) : undefined
			});
		},
		true
	);
	window.addEventListener('unhandledrejection', (event) => {
		const { msg, ...rest } = describeError(event.reason, location.origin);
		record('error', 'rejection', msg, rest);
	});
}

/** Log every request that fails: its path, its status and how long it took. */
function watchFetch(): void {
	const real = window.fetch;
	window.fetch = async (input, init) => {
		const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
		const path = here(url);
		// The log's own request: a line about it would be sent by the next one.
		if (path === LOG_PATH) return real(input, init);
		const method = (
			init?.method ?? (input instanceof Request ? input.method : 'GET')
		).toUpperCase();
		const began = performance.now();
		const failed = (sev: Severity, outcome: string, fields: Fields): void => {
			const ms = Math.round(performance.now() - began);
			record(sev, 'fetch', `${method} ${path} ${outcome} after ${ms} ms`, {
				...fields,
				method,
				url: path,
				ms,
				thread: threadIn(path) ?? undefined
			});
		};
		try {
			const response = await real(input, init);
			if (!response.ok && response.status !== 304) {
				failed(statusSeverity(response.status), `answered ${response.status}`, {
					status: response.status
				});
			}
			return response;
		} catch (error) {
			// A request the app stopped itself is not a failure.
			if (!(error instanceof DOMException && error.name === 'AbortError')) {
				failed('warn', 'did not reach the Mac', {
					error: error instanceof Error ? error.name : 'unknown',
					online: navigator.onLine
				});
			}
			throw error;
		}
	};
}

function watchLife(batcher: Batcher): void {
	document.addEventListener('visibilitychange', () => {
		record('info', 'life', document.visibilityState);
		// A page in the background may never run again: send what is held.
		if (document.visibilityState === 'hidden') void batcher.flush(true);
	});
	window.addEventListener('pagehide', () => void batcher.flush(true));
	window.addEventListener('pageshow', (event) => {
		if (event.persisted) record('info', 'life', 'restored from the page cache');
	});
	window.addEventListener('online', () => record('info', 'net', 'online'));
	window.addEventListener('offline', () => record('warn', 'net', 'offline'));
}

/** What `service-worker.ts` tells the page, for this log. */
interface WorkerNote {
	type: 'log';
	sev: Severity;
	msg: string;
	/** The build the worker is from, and the cache it serves the shell from. */
	version: string;
	cache: string;
	caches?: string[];
	/** The answer to this page's own question: which worker serves it. */
	hello?: boolean;
}

/**
 * The service worker's side of a stale app: which worker controls the page,
 * which caches exist, and each step of a new worker taking over.
 */
function watchWorker(): void {
	const workers = navigator.serviceWorker;
	if (!workers) {
		record('warn', 'sw', 'no service worker here');
		return;
	}
	workers.addEventListener('message', (event) => {
		const note = event.data as Partial<WorkerNote> | null;
		if (note?.type !== 'log' || typeof note.msg !== 'string') return;
		// The worker that serves this page is from another build: the page
		// then runs files that worker's cache does not hold.
		const other = note.hello === true && note.version !== version;
		record(
			other ? 'warn' : (note.sev ?? 'info'),
			'sw',
			other ? `${note.msg}, not the page's build` : note.msg,
			{
				sw: note.version,
				cache: note.cache,
				caches: note.caches
			}
		);
	});
	// The first worker of a first visit takes control too: that is not an update.
	let controlled = workers.controller !== null;
	workers.addEventListener('controllerchange', () => {
		record('info', 'sw', controlled ? 'another worker took control' : 'first worker took control');
		controlled = true;
	});
	workers.controller?.postMessage({ type: 'log-hello' });

	void (async () => {
		const registration = await workers.getRegistration();
		const names = await caches.keys();
		const waiting = registration?.waiting ?? null;
		record(
			waiting ? 'warn' : 'info',
			'sw',
			[
				workers.controller ? 'page controlled' : 'page not controlled',
				registration ? `worker ${registration.active?.state ?? 'not active'}` : 'not registered',
				...(waiting ? ['a new worker waits'] : []),
				`caches: ${names.join(' ') || 'none'}`
			].join(', '),
			{ controlled: workers.controller !== null, caches: names }
		);
	})().catch(() => {
		// No cache storage (a private window): the worker lines still come.
	});

	void workers.ready.then((registration) => {
		registration.addEventListener('updatefound', () => {
			const next = registration.installing;
			if (!next) return;
			record('info', 'sw', 'new worker found');
			next.addEventListener('statechange', () =>
				record(next.state === 'redundant' ? 'warn' : 'info', 'sw', `new worker ${next.state}`)
			);
		});
	});
}
