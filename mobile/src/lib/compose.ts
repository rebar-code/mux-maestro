/** The most text the Mac takes in one message, in UTF-8 bytes. */
export const TEXT_MAX_BYTES = 8192;

/** How many lines the text box grows to before it scrolls inside. */
export const BOX_MAX_LINES = 8;
/** The most of the visible screen the text box may take. */
export const BOX_MAX_SHARE = 0.4;
/** The height of one line of the box, when it cannot be measured. */
export const BOX_LINE = 22;
/** A touch target's least height: the box is never shorter. */
export const BOX_MIN = 44;

/**
 * Text as the Mac takes it: line ends are newlines. A paste from another
 * system can carry carriage returns, which the Mac refuses.
 */
export function normalizeText(text: string): string {
	return text.replace(/\r\n?/g, '\n');
}

const encoder = new TextEncoder();

/** The size of `text` as it is sent. */
export function byteLength(text: string): number {
	return encoder.encode(text).length;
}

/** How many bytes `text` is over what the Mac takes. 0: it fits. */
export function bytesOver(text: string): number {
	return Math.max(0, byteLength(normalizeText(text).trim()) - TEXT_MAX_BYTES);
}

/** The label for a text that is too long to send, or `null` when it fits. */
export function limitLabel(text: string): string | null {
	const over = bytesOver(text);
	return over ? `Too long by ${over} ${over === 1 ? 'byte' : 'bytes'}` : null;
}

/**
 * The tallest the text box gets, in pixels: so many lines, or so much of the
 * visible screen, whichever is less. `chrome` is its padding and border.
 */
export function boxCap(lineHeight: number, chrome: number, viewport: number): number {
	// Measured before the styles are in, a line has no height yet: the cap still holds.
	const line = Number.isFinite(lineHeight) && lineHeight > 0 ? lineHeight : BOX_LINE;
	const byLines = BOX_MAX_LINES * line + (Number.isFinite(chrome) ? chrome : BOX_LINE);
	const byScreen = Math.floor(viewport * BOX_MAX_SHARE);
	return Math.max(BOX_MIN, Math.round(Math.min(byLines, byScreen)));
}

/**
 * Whether the device types on real keys. A mouse or trackpad that can hover
 * comes with a keyboard; a touch screen brings up its own, where Return has
 * to stay a new line.
 */
export function hasHardwareKeyboard(pointer: { fine: boolean; hover: boolean }): boolean {
	return pointer.fine && pointer.hover;
}

/** One key press in the text box, and where it happened. */
export interface EnterPress {
	key: string;
	shiftKey: boolean;
	metaKey: boolean;
	ctrlKey: boolean;
	isComposing: boolean;
	/** 229 while an input method composes, also where `isComposing` does not say so. */
	keyCode: number;
	/** The device has a pointer that is fine and hovers: it types on real keys. */
	finePointer: boolean;
	/** The text box has the focus. */
	focused: boolean;
	/** The on-screen keyboard is up: the visible screen is shorter than the page. */
	keyboardUp: boolean;
}

/**
 * Whether this key press sends the message.
 *
 * - Shift+Enter is a new line, always.
 * - Cmd+Enter and Ctrl+Enter send, everywhere.
 * - Enter sends on real keys: a fine hovering pointer, or a touch device whose
 *   box has the focus while no on-screen keyboard is up (a keyboard is attached).
 * - Return on an on-screen keyboard is a new line.
 * - A key that belongs to an input-method composition never sends.
 */
export function enterSends(press: EnterPress): boolean {
	if (press.key !== 'Enter') return false;
	if (press.isComposing || press.keyCode === 229) return false;
	if (press.shiftKey) return false;
	if (press.metaKey || press.ctrlKey) return true;
	if (press.finePointer) return true;
	return press.focused && !press.keyboardUp;
}

/**
 * What stays in the box after `sent` went out. The box may have more in it by
 * then: what was typed while the send was on its way is kept. A box that no
 * longer starts with what was sent was changed in another way, and is left.
 */
export function remainingDraft(current: string, sent: string): string {
	const now = normalizeText(current);
	const lead = now.length - now.trimStart().length;
	if (!now.startsWith(sent, lead)) return current;
	return now.slice(lead + sent.length).trimStart();
}
