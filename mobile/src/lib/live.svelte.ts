import { ApiError, fetchConfig, fetchHosts, fetchThreads } from './api';
import type { Grouping } from './group';
import type { Capability, Config, Host, Thread } from './types';

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
		} catch (error) {
			if (error instanceof ApiError && error.forbidden) this.forbidden = true;
		}
	};
}

export const live = new Live();

/**
 * Whether the Mac has switched a feature on. A feature that is off is hidden,
 * not drawn disabled.
 */
export function can(capability: Capability): boolean {
	return live.config?.capabilities[capability] === true;
}

/** Attachment for the app root: the event stream and the clock, while mounted. */
export function connect(): () => void {
	const source = new EventSource('/api/events');
	source.addEventListener('threads', (event) => {
		live.forbidden = false;
		live.setThreads(
			(JSON.parse((event as MessageEvent<string>).data) as { threads: Thread[] }).threads
		);
	});
	source.addEventListener('hosts', (event) => {
		live.setHosts((JSON.parse((event as MessageEvent<string>).data) as { hosts: Host[] }).hosts);
	});
	source.addEventListener('config', (event) => {
		live.setConfig(JSON.parse((event as MessageEvent<string>).data) as Config);
	});
	// The stream cannot say why it failed; a plain request can (403), and it
	// also fills the lists while the stream reconnects on its own.
	let asking = false;
	source.addEventListener('error', () => {
		if (asking) return;
		asking = true;
		void live.refresh().finally(() => (asking = false));
	});
	const clock = setInterval(() => (live.now = nowSeconds()), 5000);
	return () => {
		source.close();
		clearInterval(clock);
	};
}
