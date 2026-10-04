import type { BarKey } from './reply';

/** The most bytes in one message to the Mac. The Mac refuses a larger one. */
export const MAX_MESSAGE = 2048;

const PLAIN: Record<string, string> = {
	Escape: '\x1b',
	Tab: '\t',
	BTab: '\x1b[Z',
	Enter: '\r'
};
const ARROWS: Record<string, string> = { Up: 'A', Down: 'B', Right: 'C', Left: 'D' };

/** The control character of a key: `c` gives Ctrl+C. null when it has none. */
export function ctrlChar(char: string): string | null {
	if (char.length !== 1) return null;
	const code = char.toUpperCase().charCodeAt(0);
	// `@` to `_`: Ctrl clears the two top bits. `?` is delete.
	if (code >= 0x40 && code <= 0x5f) return String.fromCharCode(code & 0x1f);
	return char === '?' ? '\x7f' : null;
}

/**
 * What a key of the key bar types into a live terminal. `application` is the
 * pane's cursor-key mode: a full-screen program asks for arrows in another form.
 */
export function barKeyText(key: BarKey, application: boolean): string | null {
	if (key.insert !== undefined) return key.insert;
	const name = key.send;
	if (name === undefined) return null;
	if (name in PLAIN) return PLAIN[name];
	if (name in ARROWS) return `\x1b${application ? 'O' : '['}${ARROWS[name]}`;
	const ctrl = /^C-([a-z])$/.exec(name);
	return ctrl ? ctrlChar(ctrl[1]) : null;
}

/**
 * What the keyboard typed, with sticky Ctrl applied: one character becomes
 * its control character. Anything else goes as it is. Ctrl holds for one key.
 */
export function typed(data: string, ctrl: boolean): string {
	return ctrl ? (ctrlChar(data) ?? data) : data;
}

/** `text` as the messages to send: UTF-8, each at most `MAX_MESSAGE` bytes. */
export function messages(text: string, size = MAX_MESSAGE): Uint8Array<ArrayBuffer>[] {
	const bytes = new TextEncoder().encode(text);
	const out: Uint8Array<ArrayBuffer>[] = [];
	for (let at = 0; at < bytes.length; at += size) out.push(bytes.subarray(at, at + size));
	return out;
}

/** Messages sent at once, and the wait before the next lot. */
export const BATCH = 32;
export const BATCH_MS = 250;

/**
 * Sends messages in order, a lot at a time. What is typed goes at once. A long
 * paste is many messages, and the Mac closes a socket that sends too many too
 * fast: 32 each quarter second is well under what it allows.
 */
export class Pacer<T> {
	private queue: T[] = [];
	private timer: ReturnType<typeof setTimeout> | null = null;

	constructor(
		private readonly send: (message: T) => void,
		private readonly later: (
			run: () => void,
			ms: number
		) => ReturnType<typeof setTimeout> = setTimeout
	) {}

	push(messages: T[]): void {
		this.queue.push(...messages);
		if (this.timer === null) this.drain();
	}

	/** Forget what is not sent: the socket it was for has gone. */
	clear(): void {
		this.queue = [];
		if (this.timer !== null) clearTimeout(this.timer);
		this.timer = null;
	}

	private drain = (): void => {
		this.timer = null;
		for (const message of this.queue.splice(0, BATCH)) this.send(message);
		if (this.queue.length > 0) this.timer = this.later(this.drain, BATCH_MS);
	};
}
