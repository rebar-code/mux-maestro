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

/**
 * Whether this key press sends the message. Enter on real keys does; with
 * Shift it is a new line. On a touch keyboard Return is always a new line, and
 * a key that ends an input-method composition never sends.
 */
export function enterSends(press: {
	key: string;
	shiftKey: boolean;
	isComposing: boolean;
	hardware: boolean;
}): boolean {
	return press.key === 'Enter' && press.hardware && !press.shiftKey && !press.isComposing;
}
