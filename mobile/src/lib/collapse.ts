import { dotClass, type Dot } from './format';
import type { Thread } from './types';

/** What a collapsed session shows for all of its windows. */
export type SummaryStatus = Dot;

/** Most urgent first. */
const ORDER: Dot[] = ['waiting', 'unviewed', 'busy', 'flagged', 'viewed', 'idle', 'none'];

/** A session on a host: the key its collapsed state is stored under. */
export function sessionKey(host: string, session: string): string {
	return `${host}/${session}`;
}

/**
 * The strongest dot among a session's threads, read the way each row's dot
 * is drawn (`dotClass`): one that needs you wins, then one that finished and
 * was not opened, then one that is running, then a flagged one, then the quiet ones. A collapsed
 * session must never hide a thread that needs the user.
 */
export function summaryStatus(
	threads: Pick<Thread, 'status' | 'idleStage' | 'indicator'>[]
): SummaryStatus {
	const shown = new Set(threads.map((thread) => dotClass(thread)));
	return ORDER.find((dot) => shown.has(dot)) ?? 'none';
}

/** What a screen reader hears for the summary dot. */
export const SUMMARY_LABEL: Record<SummaryStatus, string> = {
	waiting: 'needs you',
	unviewed: 'done',
	busy: 'running',
	flagged: 'flagged',
	viewed: 'idle',
	idle: 'idle',
	none: 'idle'
};

/**
 * An element id for a session's windows. A session name can hold a space or
 * any other character; an id (and the `aria-controls` that points at it)
 * cannot hold a space. Letters, digits, `-` and `_` stay; every other
 * character becomes `.` and its code point, so two keys never share an id.
 */
export function sessionDomId(key: string): string {
	return (
		's-' +
		[...key]
			.map((char) => (/[A-Za-z0-9_-]/.test(char) ? char : `.${char.codePointAt(0)?.toString(16)}`))
			.join('')
	);
}

/**
 * `keys` without the sessions that no longer exist; the same set when every
 * key is still live. Keeps the stored list from growing for ever.
 */
export function pruned(
	keys: Set<string>,
	threads: Pick<Thread, 'host' | 'session'>[]
): Set<string> {
	const live = new Set(threads.map((thread) => sessionKey(thread.host, thread.session)));
	const kept = [...keys].filter((key) => live.has(key));
	return kept.length === keys.size ? keys : new Set(kept);
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
