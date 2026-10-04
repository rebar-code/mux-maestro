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
