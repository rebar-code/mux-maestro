import type { Thread } from './types';

/** What a collapsed session shows for all of its windows. */
export type SummaryStatus = 'waiting' | 'busy' | 'idle';

/** A session on a host: the key its collapsed state is stored under. */
export function sessionKey(host: string, session: string): string {
	return `${host}/${session}`;
}

/**
 * The strongest status among a session's threads: one that needs you wins,
 * then one that is running, then idle (sleeping or unknown count as idle). A
 * collapsed session must never hide a thread that needs the user.
 */
export function summaryStatus(threads: Pick<Thread, 'status'>[]): SummaryStatus {
	if (threads.some((thread) => thread.status === 'waiting')) return 'waiting';
	if (threads.some((thread) => thread.status === 'busy')) return 'busy';
	return 'idle';
}

/** The stored value as a set of session keys. Anything unreadable is "none". */
export function parseCollapsed(raw: string | null): Set<string> {
	if (!raw) return new Set();
	try {
		const value: unknown = JSON.parse(raw);
		if (!Array.isArray(value)) return new Set();
		return new Set(value.filter((key): key is string => typeof key === 'string'));
	} catch {
		return new Set();
	}
}

export function serializeCollapsed(keys: Set<string>): string {
	return JSON.stringify([...keys].sort());
}

/** A new set with `key`; the same set when it was already in it. */
export function collapsed(keys: Set<string>, key: string): Set<string> {
	return keys.has(key) ? keys : new Set([...keys, key]);
}

/** A new set without `key`; the same set when it was not in it. */
export function expanded(keys: Set<string>, key: string): Set<string> {
	if (!keys.has(key)) return keys;
	const next = new Set(keys);
	next.delete(key);
	return next;
}

/**
 * Whether a session shows as collapsed. The session that holds the thread the
 * user just opened is always shown open, even before the stored state is
 * updated (the thread list may not have loaded yet when a link opens a thread).
 */
export function isCollapsed(
	keys: Set<string>,
	key: string,
	threads: Pick<Thread, 'id'>[],
	opened: string | null
): boolean {
	if (opened !== null && threads.some((thread) => thread.id === opened)) return false;
	return keys.has(key);
}
