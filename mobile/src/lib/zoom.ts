export const ZOOM_MAX = 5;
/** What a double tap or the zoom button goes to. */
export const ZOOM_STEP = 2.5;

/** The scale after two fingers went from `from` apart to `to` apart. */
export function pinchScale(scale: number, from: number, to: number): number {
	if (from <= 0) return scale;
	return Math.min(Math.max((scale * to) / from, 1), ZOOM_MAX);
}

/** Keep a zoomed image over its frame: it never slides past its own edge. */
export function clampPan(offset: number, scale: number, size: number): number {
	const max = (size * (scale - 1)) / 2;
	return Math.min(Math.max(offset, -max), max);
}
