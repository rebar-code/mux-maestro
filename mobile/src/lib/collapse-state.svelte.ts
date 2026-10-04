import {
	collapsed,
	expanded,
	parseCollapsed,
	pruned,
	serializeCollapsed,
	sessionKey
} from './collapse';
import type { Thread } from './types';

const KEY = 'mm.collapsed';

/** The part of `Storage` this needs. */
export interface KeyValueStore {
	getItem(key: string): string | null;
	setItem(key: string, value: string): void;
}

/** Which sidebar sessions are collapsed, kept on this device. */
export class Collapse {
	keys = $state.raw(parseCollapsed(null));
	/** The thread the user last opened by a link; its session shows open. */
	opened = $state<string | null>(null);

	private readonly storage: () => KeyValueStore;
	private readonly threads: () => Thread[] | null;

	/**
	 * `storage` is asked for on each use: reading `localStorage` itself can
	 * throw where storage is blocked. `threads` is the live list, or null
	 * before it has loaded.
	 */
	constructor(storage: () => KeyValueStore, threads: () => Thread[] | null) {
		this.storage = storage;
		this.threads = threads;
		// Read before the first paint, so a collapsed session never flashes open.
		try {
			this.keys = parseCollapsed(storage().getItem(KEY));
		} catch {
			// Blocked storage: nothing is collapsed.
		}
	}

	/** Store the state, without sessions that no longer exist. */
	private save(): void {
		const threads = this.threads();
		// Not before the list has loaded: every key would look stale.
		if (threads) this.keys = pruned(this.keys, threads);
		try {
			this.storage().setItem(KEY, serializeCollapsed(this.keys));
		} catch {
			// Storage is full or blocked: the state lasts for this visit only.
		}
	}

	/**
	 * The header of the session that holds `threads` was tapped. `shut` is what
	 * the session shows now, which is not always what is stored: the open
	 * thread's session shows open either way, and a tap on it must collapse it.
	 */
	toggle(key: string, shut: boolean, threads: Pick<Thread, 'id'>[]): void {
		// Only a tap on the opened thread's own session lets go of it. A tap on
		// another header must not fold that session back up.
		if (threads.some((thread) => thread.id === this.opened)) this.opened = null;
		this.keys = shut ? expanded(this.keys, key) : collapsed(this.keys, key);
		this.save();
	}

	/** The user opened thread `id` from somewhere: its session expands. */
	open(id: string): void {
		this.opened = id;
		const thread = this.threads()?.find((candidate) => candidate.id === id);
		if (!thread) return;
		const next = expanded(this.keys, sessionKey(thread.host, thread.session));
		if (next === this.keys) return;
		this.keys = next;
		this.save();
	}
}
