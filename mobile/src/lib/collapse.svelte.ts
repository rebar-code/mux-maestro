import { collapsed, expanded, parseCollapsed, serializeCollapsed, sessionKey } from './collapse';
import type { Thread } from './types';

const KEY = 'mm.collapsed';

function stored(): Set<string> {
	try {
		return parseCollapsed(localStorage.getItem(KEY));
	} catch {
		return new Set();
	}
}

/** Which sidebar sessions are collapsed, kept on this device. */
class Collapse {
	/** Read before the first paint, so a collapsed session never flashes open. */
	keys = $state.raw(stored());
	/** The thread the user last opened by a link; its session shows open. */
	opened = $state<string | null>(null);

	private save(): void {
		try {
			localStorage.setItem(KEY, serializeCollapsed(this.keys));
		} catch {
			// Storage is full or blocked: the state lasts for this visit only.
		}
	}

	/**
	 * The header was tapped. `shut` is what the session shows now, which is not
	 * always what is stored: the open thread's session shows open either way,
	 * and a tap on it must collapse it.
	 */
	toggle(key: string, shut: boolean): void {
		this.opened = null;
		this.keys = shut ? expanded(this.keys, key) : collapsed(this.keys, key);
		this.save();
	}

	/** The user opened thread `id` from somewhere: its session expands. */
	open(id: string, threads: Thread[] | null): void {
		this.opened = id;
		const thread = threads?.find((candidate) => candidate.id === id);
		if (!thread) return;
		const next = expanded(this.keys, sessionKey(thread.host, thread.session));
		if (next === this.keys) return;
		this.keys = next;
		this.save();
	}
}

export const collapse = new Collapse();
