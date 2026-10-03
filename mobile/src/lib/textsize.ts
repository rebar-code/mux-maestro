/** Terminal font size in CSS pixels. Chat text follows it by ratio. */
export const MIN_SIZE = 6;
export const MAX_SIZE = 24;
export const DEFAULT_SIZE = 11;
const CHAT_BASE = 15;

export function clampSize(size: number): number {
	if (!Number.isFinite(size)) return DEFAULT_SIZE;
	return Math.min(Math.max(size, MIN_SIZE), MAX_SIZE);
}

/** One whole pixel up or down. A size between two whole pixels goes to the next one. */
export function stepSize(size: number, direction: 1 | -1): number {
	return clampSize(direction > 0 ? Math.floor(size) + 1 : Math.ceil(size) - 1);
}

/** The size during a pinch: it grows as the fingers move apart. */
export function pinchSize(startSize: number, startDistance: number, distance: number): number {
	if (startDistance <= 0) return clampSize(startSize);
	return clampSize(Math.round(((startSize * distance) / startDistance) * 10) / 10);
}

export function chatSize(size: number): number {
	return (CHAT_BASE * size) / DEFAULT_SIZE;
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
