import { shortCwd } from './format';
import type { Thread } from './types';

export type Grouping = 'host' | 'directory' | 'recent';

export const GROUPINGS: { key: Grouping; label: string }[] = [
	{ key: 'host', label: 'Host' },
	{ key: 'directory', label: 'Directory' },
	{ key: 'recent', label: 'Most Recent' }
];

export interface SessionGroup {
	key: string;
	host: string;
	hostColor: string;
	name: string;
	cwd: string;
	at: number;
	threads: Thread[];
}

export interface Section {
	key: string;
	/** null: no header above these sessions. */
	title: string | null;
	mono: boolean;
	color: string | null;
	sessions: SessionGroup[];
}

/** When you last typed into a thread; else when it last did anything. */
export function recency(thread: Thread): number {
	return thread.lastPrompt?.at ?? thread.lastActivityAt ?? thread.sessionActivity;
}

export function sessions(threads: Thread[]): SessionGroup[] {
	const byKey = new Map<string, SessionGroup>();
	for (const thread of threads) {
		const key = `${thread.host}/${thread.session}`;
		const group = byKey.get(key);
		if (group) group.threads.push(thread);
		else
			byKey.set(key, {
				key,
				host: thread.host,
				hostColor: thread.hostColor,
				name: thread.session,
				cwd: thread.cwd,
				at: 0,
				threads: [thread]
			});
	}
	return [...byKey.values()].map((group) => {
		const sorted = [...group.threads].sort(
			(a, b) => recency(b) - recency(a) || a.window - b.window || a.pane.localeCompare(b.pane)
		);
		return { ...group, threads: sorted, at: recency(sorted[0]) };
	});
}

const byName = (a: SessionGroup, b: SessionGroup): number =>
	a.name.localeCompare(b.name) || a.host.localeCompare(b.host);

export function sections(threads: Thread[], grouping: Grouping): Section[] {
	const all = sessions(threads);
	if (grouping === 'recent') {
		const sorted = [...all].sort((a, b) => b.at - a.at || byName(a, b));
		return [{ key: 'recent', title: null, mono: false, color: null, sessions: sorted }];
	}
	if (grouping === 'host') {
		// Hosts keep the order the server sent them in: local first.
		const hosts = [...new Set(threads.map((thread) => thread.host))];
		return hosts.map((host) => {
			const mine = all.filter((group) => group.host === host).sort(byName);
			return { key: host, title: host, mono: false, color: mine[0].hostColor, sessions: mine };
		});
	}
	return [...all].sort(byName).map((group) => ({
		key: group.key,
		title: shortCwd(group.cwd),
		mono: true,
		color: null,
		sessions: [group]
	}));
}

/** What the sidebar leaves out. Each mode after `sleepy` keeps more of the sleeping threads. */
export type Filter = 'off' | 'sleepy' | '2h' | 'today';

export const FILTERS: { key: Exclude<Filter, 'off'>; label: string }[] = [
	{ key: 'sleepy', label: 'Sleepy' },
	{ key: '2h', label: '2 hours' },
	{ key: 'today', label: 'Today' }
];

export const isFilter = (value: unknown): value is Filter =>
	value === 'off' || FILTERS.some((option) => option.key === value);

/** Epoch seconds from which a sleeping thread still shows. `null`: none does. */
function shownSince(filter: Filter, now: number): number | null {
	if (filter === '2h') return now - 2 * 3600;
	if (filter !== 'today') return null;
	const day = new Date(now * 1000);
	day.setHours(0, 0, 0, 0);
	return Math.floor(day.getTime() / 1000);
}

/**
 * The threads the sidebar shows under `filter`. A thread that is not asleep
 * always shows. The wider modes also keep a sleeping one that was written
 * since their time. `now`: epoch seconds.
 */
export function visible(threads: Thread[], filter: Filter, now: number): Thread[] {
	if (filter === 'off') return threads;
	const since = shownSince(filter, now);
	return threads.filter(
		(thread) =>
			thread.idleStage !== 'dozing' ||
			(since !== null && thread.lastActivityAt !== null && thread.lastActivityAt >= since)
	);
}

export function counts(threads: Thread[]): { waiting: number; busy: number; dozing: number } {
	return {
		waiting: threads.filter((thread) => thread.status === 'waiting').length,
		busy: threads.filter((thread) => thread.status === 'busy').length,
		dozing: threads.filter((thread) => thread.idleStage === 'dozing').length
	};
}
