import {
	adoptPairingLink,
	ApiError,
	fetchConfig,
	fetchHosts,
	fetchThreads,
	hasToken,
	readEvents,
	setToken
} from './api';
import { tokenFrom } from './pairing';
import type { Frame } from './sse';
import type { Grouping } from './group';
import { manager } from './manager.svelte';
import type { Capability, Config, Host, ManagerLive, Thread } from './types';

const THREADS_KEY = 'mm.threads';
const HOSTS_KEY = 'mm.hosts';
const CONFIG_KEY = 'mm.config';
const GROUPING_KEY = 'mm.grouping';

function read<T>(key: string): T | null {
	try {
		const raw = localStorage.getItem(key);
		return raw ? (JSON.parse(raw) as T) : null;
	} catch {
		return null;
	}
}

function write(key: string, value: unknown): void {
	try {
		localStorage.setItem(key, JSON.stringify(value));
	} catch {
		// Storage is full or blocked: the lists still work, only the instant open is lost.
	}
}

const nowSeconds = (): number => Math.floor(Date.now() / 1000);

/**
 * The thread and host lists. They start from the copy the last visit left in
 * the browser, so the sidebar paints at once, and are then replaced by the
 * server's. `null` means there is nothing to show yet: draw skeleton rows.
 */
class Live {
	threads = $state.raw<Thread[] | null>(read<Thread[]>(THREADS_KEY));
	hosts = $state.raw<Host[] | null>(read<Host[]>(HOSTS_KEY));
	/** The server refused this device. */
	forbidden = $state(false);
	/** This phone holds no pairing token the Mac accepts. */
	unpaired = $state(!hasToken());
	/** Epoch seconds, ticking, so ages on screen stay current. */
	now = $state(nowSeconds());
	/** What the Mac allows and prefers. Cached too, so it is there at first paint. */
	config = $state.raw<Config | null>(read<Config>(CONFIG_KEY));
	/** The grouping picked on this phone. Until there is one, the Mac's default applies. */
	private picked = $state<Grouping | null>(read<Grouping>(GROUPING_KEY));
	readonly grouping: Grouping = $derived(this.picked ?? this.config?.grouping ?? 'recent');

	private listeners = new Set<() => void>();

	byId(id: string): Thread | undefined {
		return this.threads?.find((thread) => thread.id === id);
	}

	setGrouping(grouping: Grouping): void {
		this.picked = grouping;
		write(GROUPING_KEY, grouping);
	}

	setThreads(threads: Thread[]): void {
		this.threads = threads;
		write(THREADS_KEY, threads);
		for (const listener of this.listeners) listener();
	}

	setHosts(hosts: Host[]): void {
		this.hosts = hosts;
		write(HOSTS_KEY, hosts);
	}

	setConfig(config: Config): void {
		this.config = config;
		write(CONFIG_KEY, config);
	}

	/** Call `listener` after each new thread list. Returns the unsubscribe. */
	onThreads(listener: () => void): () => void {
		this.listeners.add(listener);
		return () => this.listeners.delete(listener);
	}

	refresh = async (): Promise<void> => {
		try {
			const [threads, hosts, config] = await Promise.all([
				fetchThreads(),
				fetchHosts(),
				fetchConfig()
			]);
			this.forbidden = false;
			this.setThreads(threads);
			this.setHosts(hosts);
			this.setConfig(config);
			stream.ensure();
		} catch (error) {
			this.fail(error);
		}
	};

	/** Note a refusal: the token is not accepted, or this device is not allowed. */
	fail(error: unknown): void {
		if (!(error instanceof ApiError)) return;
		if (error.forbidden) this.forbidden = true;
		if (error.unpaired) {
			setToken(null);
			this.unpaired = true;
		}
	}

	apply(frame: Frame): void {
		if (frame.event === 'threads') {
			this.forbidden = false;
			this.setThreads((JSON.parse(frame.data) as { threads: Thread[] }).threads);
		} else if (frame.event === 'hosts') {
			this.setHosts((JSON.parse(frame.data) as { hosts: Host[] }).hosts);
		} else if (frame.event === 'config') {
			this.setConfig(JSON.parse(frame.data) as Config);
		} else if (frame.event === 'manager') {
			manager.apply(JSON.parse(frame.data) as ManagerLive);
		} else if (frame.event === 'manager-delta') {
			manager.append((JSON.parse(frame.data) as { text: string }).text);
		}
	}

	/**
	 * Pair with what was typed: a pairing link or a bare token. The Mac is asked
	 * first, and a token it refuses is not kept. False when the text holds no
	 * token or the Mac refuses it.
	 */
	async pair(input: string): Promise<boolean> {
		const candidate = tokenFrom(input);
		if (!candidate) return false;
		try {
			this.setConfig(await fetchConfig(candidate));
		} catch (error) {
			if (error instanceof ApiError && error.unpaired) return false;
			// Any other failure is not about the token: keep it and carry on.
		}
		this.paired(candidate);
		return true;
	}

	paired(token?: string): void {
		if (token) setToken(token);
		this.unpaired = false;
		this.forbidden = false;
		stream.start();
	}
}

export const live = new Live();

/**
 * Whether the Mac has switched a feature on. A feature that is off is hidden,
 * not drawn disabled.
 */
export function can(capability: Capability): boolean {
	return live.config?.capabilities[capability] === true;
}

const RETRY_FIRST = 1000;
const RETRY_MAX = 10_000;

/** The live event stream: one at a time, reopened when it drops. */
class Stream {
	private controller: AbortController | null = null;

	start(): void {
		this.stop();
		if (live.unpaired) return;
		const controller = new AbortController();
		this.controller = controller;
		void this.run(controller.signal);
	}

	/** Start again if a refusal had stopped it. */
	ensure(): void {
		if (!this.controller) this.start();
	}

	stop(): void {
		this.controller?.abort();
		this.controller = null;
	}

	private async run(signal: AbortSignal): Promise<void> {
		let delay = RETRY_FIRST;
		while (!signal.aborted) {
			try {
				await readEvents(signal, (frame) => {
					delay = RETRY_FIRST;
					live.apply(frame);
				});
			} catch (error) {
				if (signal.aborted) return;
				// A refusal will not change by asking again.
				if (error instanceof ApiError && (error.status === 401 || error.status === 403)) {
					live.fail(error);
					if (this.controller?.signal === signal) this.controller = null;
					return;
				}
			}
			if (signal.aborted) return;
			await new Promise((done) => setTimeout(done, delay));
			delay = Math.min(delay * 2, RETRY_MAX);
		}
	}
}

const stream = new Stream();

/** Attachment for the app root: the event stream and the clock, while mounted. */
export function connect(): () => void {
	// Again, now the router has started: it puts back the address it loaded with.
	adoptPairingLink();
	stream.start();
	// A page in the background gets no events: stop, and start again on return.
	const onVisibility = (): void => {
		if (document.visibilityState === 'visible') stream.start();
		else stream.stop();
	};
	// A pairing link opened in a tab that already shows the app only changes the fragment.
	const onHash = (): void => {
		if (adoptPairingLink()) live.paired();
	};
	document.addEventListener('visibilitychange', onVisibility);
	window.addEventListener('hashchange', onHash);
	const clock = setInterval(() => (live.now = nowSeconds()), 5000);
	return () => {
		stream.stop();
		document.removeEventListener('visibilitychange', onVisibility);
		window.removeEventListener('hashchange', onHash);
		clearInterval(clock);
	};
}
