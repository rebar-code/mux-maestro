import { threadTitle } from './format';
import type { ActionTarget, Thread } from './types';

/** What a long press was on. */
export type MenuTarget =
	| { kind: 'thread'; thread: Thread }
	/** `thread`: any thread of the session. It is how the Mac is told which session. */
	| { kind: 'session'; host: string; session: string; thread: string }
	| { kind: 'host'; host: string };

export type ItemKey =
	| 'new-window'
	| 'new-session'
	| 'rename'
	| 'archive-window'
	| 'zoom-pane'
	| 'kill-pane'
	| 'kill-window'
	| 'kill-session';

export interface MenuItem {
	key: ItemKey;
	label: string;
	danger?: boolean;
}

/** The menu of a row: what the Mac shows on a right click, less what the phone cannot do. */
export function menuItems(target: MenuTarget, canKill: boolean): MenuItem[] {
	if (target.kind === 'host') return [{ key: 'new-session', label: 'New Session…' }];
	if (target.kind === 'session') {
		return [
			{ key: 'new-window', label: 'New Window…' },
			{ key: 'rename', label: 'Rename…' },
			...(canKill ? [{ key: 'kill-session', label: 'Kill Session', danger: true } as const] : [])
		];
	}
	return [
		{ key: 'new-window', label: 'New Window…' },
		{ key: 'rename', label: 'Rename Window…' },
		{ key: 'archive-window', label: 'Archive Window' },
		{ key: 'zoom-pane', label: 'Zoom Pane' },
		...(canKill && target.thread.panes > 1
			? [{ key: 'kill-pane', label: 'Kill Pane', danger: true } as const]
			: []),
		...(canKill ? [{ key: 'kill-window', label: 'Kill Window', danger: true } as const] : [])
	];
}

/** What a new window starts with. */
export type StartKind = 'claude' | 'codex' | 'terminal';

export const START_ITEMS: { kind: StartKind; label: string }[] = [
	{ kind: 'claude', label: 'Claude' },
	{ kind: 'codex', label: 'Codex' },
	{ kind: 'terminal', label: 'Terminal' }
];

/** The Mac's cap on a first prompt: the bytes of the quoted word it types. */
export const PROMPT_MAX = 900;

/**
 * Whether the Mac would take `raw` as an agent's first prompt. Empty is no
 * prompt. The Mac checks again; this only saves a round trip.
 */
export function validPrompt(raw: string): boolean {
	const text = raw.replace(/\r\n/g, '\n').trim();
	if (text.startsWith('-')) return false;
	let bytes = 2 + new TextEncoder().encode(text).length;
	for (const char of text) {
		const code = char.codePointAt(0) ?? 0;
		// A control character is a key to a terminal; a new line and a tab are text.
		if (code !== 0x0a && code !== 0x09 && (code < 0x20 || (code >= 0x7f && code <= 0x9f)))
			return false;
		// A quote and a backslash are four bytes each once they are quoted.
		if (char === "'" || char === '\\') bytes += 3;
	}
	return bytes <= PROMPT_MAX;
}

/** The last step of a path: a folder's own name. */
export function folderName(path: string): string {
	return path.slice(path.lastIndexOf('/') + 1) || path;
}

/** The session a new window goes into. */
export function startTitle(target: MenuTarget): string {
	if (target.kind === 'thread') return target.thread.session;
	return target.kind === 'session' ? target.session : '';
}

export function menuTitle(target: MenuTarget): string {
	if (target.kind === 'host') return target.host;
	if (target.kind === 'session') return target.session;
	return `${target.thread.session} · ${threadTitle(target.thread)}`;
}

/** The name a rename starts from. */
export function currentName(target: MenuTarget): string {
	if (target.kind === 'thread') return target.thread.name;
	return target.kind === 'session' ? target.session : '';
}

/**
 * What the Mac is told the action is done to: always a thread. A session is
 * named by one of its threads, so a request that arrives late cannot reach a
 * newer session that took the same name.
 */
export function actionTarget(target: MenuTarget): ActionTarget | null {
	if (target.kind === 'thread') return { thread: target.thread.id };
	if (target.kind === 'session') return { thread: target.thread };
	return null;
}

export type KillKind = 'kill-pane' | 'kill-window' | 'kill-session';

/** The sentence on the kill confirmation. */
export function killWarning(kind: KillKind): string {
	if (kind === 'kill-pane') return 'This closes the pane and stops what runs in it.';
	if (kind === 'kill-window') return 'This closes the window and stops what runs in it.';
	return 'This closes every window in the session and stops what runs in them.';
}

/** The threads a kill takes away. */
export function killed(target: MenuTarget, kind: KillKind, threads: Thread[]): Thread[] {
	if (target.kind === 'thread') {
		const { thread } = target;
		if (kind === 'kill-pane') return threads.filter((other) => other.id === thread.id);
		return threads.filter(
			(other) =>
				other.host === thread.host &&
				other.session === thread.session &&
				other.window === thread.window
		);
	}
	if (target.kind === 'session') {
		return threads.filter(
			(other) => other.host === target.host && other.session === target.session
		);
	}
	return [];
}

export const NAME_MAX = 64;
const ASCII_OK = /^[A-Za-z0-9 \-_/,]$/;
const HIDDEN = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}\p{Co}\p{Cn}]/u;

/**
 * Whether the Mac would take `raw` as a session or window name. The Mac
 * checks again; this only saves a round trip.
 */
export function validName(raw: string): boolean {
	const name = raw.trim();
	if (!name || name.startsWith('-') || [...name].length > NAME_MAX) return false;
	for (const char of name) {
		const code = char.codePointAt(0) ?? 0;
		if (code < 0x80) {
			if (!ASCII_OK.test(char)) return false;
		} else if (code !== 0x200d && HIDDEN.test(char)) return false;
	}
	return true;
}

/** What to tell the human when the Mac refuses an action. */
export function refusalText(code: string | null, detail: string | null): string {
	if (detail) return detail;
	if (code === 'bad_name') return 'Name not allowed';
	if (code === 'exists') return 'Name is taken';
	if (code === 'not_found') return 'No longer there';
	if (code === 'disabled') return 'Switched off on the Mac';
	if (code === 'protected') return 'Not allowed';
	if (code === 'bad_dir') return 'Directory not offered';
	if (code === 'bad_prompt') return 'Prompt not allowed';
	if (code === 'too_large') return 'Prompt too long';
	return 'Failed';
}
