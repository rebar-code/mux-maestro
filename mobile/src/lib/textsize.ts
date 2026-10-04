/** Terminal font size in CSS pixels. Chat text follows it by ratio. */
export const MIN_SIZE = 6;
export const MAX_SIZE = 24;
export const DEFAULT_SIZE = 11;
const CHAT_BASE = 15;

export function clampSize(size: number): number {
	if (!Number.isFinite(size)) return DEFAULT_SIZE;
	return Math.min(Math.max(size, MIN_SIZE), MAX_SIZE);
}

/** The size during a pinch: it grows as the fingers move apart. */
export function pinchSize(startSize: number, startDistance: number, distance: number): number {
	if (startDistance <= 0) return clampSize(startSize);
	return clampSize(Math.round(((startSize * distance) / startDistance) * 10) / 10);
}

export function chatSize(size: number): number {
	return (CHAT_BASE * size) / DEFAULT_SIZE;
}

/** The smallest text a text box has: under 16px iOS zooms the page when the box takes the focus. */
export const BOX_MIN = 16;

/** A text box's size: the chat's, and never under `BOX_MIN`. */
export function boxSize(size: number): number {
	return Math.max(BOX_MIN, Math.round(chatSize(size) * 10) / 10);
}

export interface Anchor {
	/** Scroll position when the pinch began. */
	scroll: number;
	/** Where the fingers' midpoint was then, measured from the scroller's edge. */
	mid: number;
	/** New size over the size when the pinch began. */
	ratio: number;
	/** Where the midpoint is now. Leave out when it has not moved. */
	midNow?: number;
	/** Space before the text that does not scale (padding). */
	offset?: number;
}

/**
 * The scroll position that keeps the text under the fingers in place while
 * its size changes. With no padding and a still midpoint this is
 * `(scroll + mid) * ratio - mid`. Used once per axis.
 */
export function anchorScroll({ scroll, mid, ratio, midNow = mid, offset = 0 }: Anchor): number {
	return (scroll + mid - offset) * ratio + offset - midNow;
}
