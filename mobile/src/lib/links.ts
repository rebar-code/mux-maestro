import type { Thread } from './types';

/**
 * A `muxmaestro://` link: how the Maestro points at a pane. On the Mac the app
 * opens it. Here it is resolved against the thread list to a thread of this
 * app, so one link works in both places.
 */
export type ThreadLink =
	/** `muxmaestro://open?session=…&window=…&pane=…&host=…`: a tmux address. */
	| { kind: 'open'; host: string; session: string; window: number | null; pane: string | null }
	/** `muxmaestro://thread/<id>`: the pane that runs that Claude or Codex conversation now. */
	| { kind: 'agent'; id: string };

const LINK = /^muxmaestro:\/\/(open|thread)(?:\/([^?#]*))?(?:\?([^#]*))?$/i;
const AGENT_ID = /^[A-Za-z0-9-]+$/;
const LOCAL = 'localhost';

/** Null for another scheme, an unknown action, a missing session or a window that is not a number. */
export function parseThreadLink(href: string): ThreadLink | null {
	const match = LINK.exec(href.trim());
	if (!match) return null;
	const [, action, path, query] = match;
	if (action.toLowerCase() === 'thread') {
		return path && AGENT_ID.test(path) && !query ? { kind: 'agent', id: path } : null;
	}
	if (path) return null;
	const params = new URLSearchParams(query ?? '');
	const session = params.get('session');
	if (!session) return null;
	const window = params.get('window');
	if (window !== null && window !== '' && !/^\d+$/.test(window)) return null;
	return {
		kind: 'open',
		host: params.get('host') || LOCAL,
		session,
		window: window ? Number(window) : null,
		pane: params.get('pane') || null
	};
}

/**
 * The thread a link opens, by the rule the Mac uses for a pointer: the named
 * pane, else the first thread of the window, else the session's thread that
 * waits, then the one that works, then its first.
 */
export function threadForLink(link: ThreadLink, threads: Thread[]): Thread | null {
	if (link.kind === 'agent') {
		const id = link.id.toLowerCase();
		return threads.find((thread) => thread.agent?.toLowerCase() === id) ?? null;
	}
	const rows = threads.filter(
		(thread) =>
			thread.host === link.host &&
			thread.session === link.session &&
			(link.window === null || thread.window === link.window)
	);
	const named = rows.find((thread) => thread.pane === link.pane);
	if (named) return named;
	const urgent =
		link.window === null
			? (rows.find((thread) => thread.status === 'waiting') ??
				rows.find((thread) => thread.status === 'busy'))
			: undefined;
	return urgent ?? rows[0] ?? null;
}

/** What a bare link shows: `session:window`, with `host/` in front for another host. */
export function linkLabel(link: ThreadLink): string {
	if (link.kind === 'agent') return `thread ${link.id.slice(0, 8)}`;
	const address = link.window === null ? link.session : `${link.session}:${link.window}`;
	return link.host === LOCAL ? address : `${link.host}/${address}`;
}
