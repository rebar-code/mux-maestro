import type { ChatMessage, Command, Thread } from './types';

/** One key of the key bar: it presses a key in the pane, types a character, or is Ctrl. */
export interface BarKey {
	label: string;
	aria: string;
	/** The key name the Mac takes. */
	send?: string;
	/** A character for the text box. It is not sent as a key. */
	insert?: string;
	ctrl?: true;
}

export const BAR_KEYS: readonly BarKey[] = [
	{ label: 'Esc', aria: 'Escape', send: 'Escape' },
	{ label: 'Tab', aria: 'Tab', send: 'Tab' },
	{ label: 'Sh+Tab', aria: 'Shift Tab', send: 'BTab' },
	{ label: 'Ctrl', aria: 'Control', ctrl: true },
	{ label: 'Ctrl+C', aria: 'Control C', send: 'C-c' },
	{ label: '←', aria: 'Left', send: 'Left' },
	{ label: '↓', aria: 'Down', send: 'Down' },
	{ label: '↑', aria: 'Up', send: 'Up' },
	{ label: '→', aria: 'Right', send: 'Right' },
	{ label: '⏎', aria: 'Enter', send: 'Enter' },
	{ label: '/', aria: 'Slash', insert: '/' },
	{ label: '~', aria: 'Tilde', insert: '~' },
	{ label: '|', aria: 'Pipe', insert: '|' },
	{ label: '-', aria: 'Dash', insert: '-' }
];

const NAMED = new Set(['Enter', 'Escape', 'Up', 'Down', 'Left', 'Right', 'Tab', 'BTab']);

/** Whether the Mac takes `key`: the named keys, `C-a` to `C-z`, `1` to `9`. */
export function isKeyName(key: string): boolean {
	return NAMED.has(key) || /^C-[a-z]$/.test(key) || /^[1-9]$/.test(key);
}

/** The keys a bar shows. Without a text box, only the keys that go to the pane. */
/** What the key bar's taps go to: a thread's replies, or its live terminal. */
export interface KeySink {
	/** Sticky Ctrl is on. */
	readonly ctrl: boolean;
	tap(key: BarKey): void;
}

export function barKeys(composer: boolean): readonly BarKey[] {
	return composer ? BAR_KEYS : BAR_KEYS.filter((key) => key.send !== undefined);
}

export type CtrlEvent = { type: 'toggle' } | { type: 'input'; data: string | null };

export interface CtrlState {
	on: boolean;
	/** The key to send in place of the typed letter. */
	key: string | null;
}

/**
 * Sticky Ctrl. A tap switches it on or off. It holds for one key: a letter
 * typed next is not text, it becomes `C-<letter>`; anything else is handled
 * as it always is. Either way Ctrl switches off.
 */
export function ctrlReduce(on: boolean, event: CtrlEvent): CtrlState {
	if (event.type === 'toggle') return { on: !on, key: null };
	if (!on) return { on: false, key: null };
	const letter = event.data?.toLowerCase() ?? '';
	return { on: false, key: /^[a-z]$/.test(letter) ? `C-${letter}` : null };
}

/** How long sticky Ctrl waits for its key before it switches off by itself. */
export const CTRL_MS = 5000;

/** The key presses that wait their turn: a thread takes one write at a time. */
export const KEY_QUEUE_MAX = 8;

/** A key that waits its turn, with the prompt that was on screen when it was tapped. */
export interface QueuedKey {
	key: string;
	/** The id of the card the human saw at the tap, or `null` with no card. */
	prompt: string | null;
	/** The pane's Terminal view was the one on screen at the tap. */
	terminal: boolean;
}

/**
 * `queue` with `key` at its end. `prompt` is the card on screen now, at the
 * tap, and `terminal` whether the pane's own text was: a key answers what the
 * human saw, not what the pane shows by the time the key is sent. A full
 * queue drops the key.
 */
export function queueKey(
	queue: readonly QueuedKey[],
	key: string,
	prompt: string | null,
	terminal = false
): QueuedKey[] {
	return queue.length >= KEY_QUEUE_MAX ? [...queue] : [...queue, { key, prompt, terminal }];
}

/**
 * What the slash list filters by: the text after the slash, while the box
 * holds only a command name. `null` when the list does not show.
 */
export function slashQuery(text: string): string | null {
	return /^\/(\S*)$/.exec(text)?.[1] ?? null;
}

/** The commands whose name starts with `query`, then those that contain it. */
export function filterCommands(commands: Command[], query: string): Command[] {
	const wanted = query.toLowerCase();
	const starts: Command[] = [];
	const holds: Command[] = [];
	for (const command of commands) {
		const at = command.name.toLowerCase().indexOf(wanted);
		if (at === 0) starts.push(command);
		else if (at > 0) holds.push(command);
	}
	return [...starts, ...holds];
}

/**
 * The thread the Next bar opens: the one that has waited longest, when the
 * open thread does not itself wait. `null` when there is no bar.
 */
export function nextWaiting(threads: Thread[], open: string): Thread | null {
	if (threads.find((thread) => thread.id === open)?.status === 'waiting') return null;
	const waiting = threads.filter((thread) => thread.status === 'waiting' && thread.id !== open);
	if (!waiting.length) return null;
	return waiting.reduce((first, thread) =>
		(thread.since ?? Infinity) < (first.since ?? Infinity) ? thread : first
	);
}

const LABELS: Record<string, string> = {
	busy: 'Busy',
	waiting: 'Waiting on a prompt',
	disabled: 'Off on the Mac',
	not_found: 'Closed',
	unavailable: 'Not available',
	bad_key: 'Key not allowed',
	stale: 'Prompt changed',
	no_input: 'No input box',
	not_sent: 'Not sent',
	unseen: 'Open the terminal to answer',
	no_option: 'Not a choice on the card'
};

/** What the Mac said when it refused a write. `ApiError` is one. */
export interface Refusal {
	status: number;
	code: string | null;
	detail: string | null;
	reason?: string | null;
	cleared?: boolean | null;
}

/** The highest option a key or the answer route can pick. */
export const MAX_ANSWER = 9;

/** Whether the phone can answer with option `n`: the pane has keys for 1 to 9 only. */
export function canAnswer(n: number): boolean {
	return Number.isInteger(n) && n >= 1 && n <= MAX_ANSWER;
}

/**
 * The pane may show a prompt the phone has not drawn: it refused because it
 * waits, because the prompt the phone named is not the one it shows, or
 * because it shows one that cannot be read.
 */
export function needsPrompt(refusal: Refusal | null): boolean {
	if (refusal?.status !== 409) return false;
	return (
		refusal.code === 'waiting' ||
		refusal.code === 'stale' ||
		refusal.code === 'unseen' ||
		(refusal.code === 'not_sent' && refusal.reason === 'waiting')
	);
}

/**
 * What a refused reply leaves on the phone. A text the Mac pasted and could
 * not take out again is still in the pane: the box is emptied, so Send cannot
 * submit it twice. Every other refusal keeps the draft, to send again.
 */
export function textRefusal(refusal: Refusal | null): { note: string; keepDraft: boolean } {
	if (refusal?.code === 'not_sent' && refusal.cleared === false)
		return { note: 'Left in the pane', keepDraft: false };
	return { note: refusalLabel(refusal, 'text'), keepDraft: true };
}

/** The status line for a write the Mac refused: its sentence, or a short label. */
export function refusalLabel(
	refusal: Refusal | null,
	what: 'text' | 'file' | 'key' | 'answer' = 'text'
): string {
	if (!refusal) return 'No answer';
	if (refusal.detail) return refusal.detail;
	if (refusal.status === 413) return what === 'file' ? 'Too big' : 'Too long';
	if (refusal.code && LABELS[refusal.code]) return LABELS[refusal.code];
	if (refusal.status === 400) return 'Cannot be sent';
	if (refusal.status === 404) return LABELS.not_found;
	return 'No answer';
}

/** A turn this phone spoke into the thread, while it runs. */
export interface LiveTurn {
	prompt: string;
	reply: string;
}

/**
 * Which lines of a spoken turn the chat still has to draw itself. The
 * transcript gets the prompt, and then the reply, while the turn runs: a line
 * the chat already has is not drawn twice.
 */
export function liveLines(
	messages: ChatMessage[],
	turn: LiveTurn | null
): { prompt: boolean; reply: boolean } {
	if (!turn) return { prompt: false, reply: false };
	const at = messages.findLastIndex(
		(message) => message.role === 'user' && message.text === turn.prompt
	);
	if (at < 0) return { prompt: true, reply: turn.reply !== '' };
	const answered = messages.slice(at + 1).some((message) => message.role === 'assistant');
	return { prompt: false, reply: !answered && turn.reply !== '' };
}
