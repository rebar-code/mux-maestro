import { threadTitle } from './format';
import { recency, sessions, type SessionGroup } from './group';
import type { Host, Thread } from './types';

export const SEARCH_MAX = 80;
/** The most windows one search lists. */
const WINDOWS_MAX = 30;

export interface SearchResults {
	hosts: Host[];
	sessions: SessionGroup[];
	threads: Thread[];
}

const NONE: SearchResults = { hosts: [], sessions: [], threads: [] };

/** The words of a query, in lower case. */
const terms = (query: string): string[] => query.toLowerCase().split(/\s+/).filter(Boolean);

/** Every word is somewhere in one of the fields. */
const matches = (words: string[], fields: (string | null | undefined)[]): boolean => {
	const text = fields.filter(Boolean).join('\n').toLowerCase();
	return words.every((word) => text.includes(word));
};

/** A name that starts with what was typed comes first; `at` orders the rest, newest first. */
function ranked<T>(
	items: T[],
	query: string,
	name: (item: T) => string,
	at: (item: T) => number
): T[] {
	const typed = query.trim().toLowerCase();
	const first = (item: T): number => (name(item).toLowerCase().startsWith(typed) ? 0 : 1);
	return [...items].sort((a, b) => first(a) - first(b) || at(b) - at(a));
}

/** The hosts, sessions and windows a query finds. An empty query finds nothing. */
export function searchAll(query: string, threads: Thread[], hosts: Host[]): SearchResults {
	const words = terms(query);
	if (words.length === 0) return NONE;
	return {
		hosts: ranked(
			// "local" finds this Mac, whatever its name is.
			hosts.filter((host) => matches(words, [host.name, host.local ? 'local' : null])),
			query,
			(host) => host.name,
			(host) => host.threads
		),
		sessions: ranked(
			sessions(threads).filter((session) =>
				matches(words, [session.name, session.host, session.cwd])
			),
			query,
			(session) => session.name,
			(session) => session.at
		),
		threads: ranked(
			threads.filter((thread) =>
				matches(words, [
					threadTitle(thread),
					thread.session,
					thread.host,
					thread.command,
					thread.cwd,
					thread.agent
				])
			),
			query,
			(thread) => thread.name,
			recency
		).slice(0, WINDOWS_MAX)
	};
}
