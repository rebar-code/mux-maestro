/**
 * The math behind the horizontal gestures. The screen is an ordered row of
 * pages with the sidebar drawer one step left of page 0. Kept free of the DOM
 * so it is tested directly.
 */

export type DragKind = 'drawer-open' | 'drawer-close' | 'page' | 'hscroll' | 'swipe' | 'none';

export interface DragContext {
	/** Finger movement so far: positive is a right swipe. */
	dx: number;
	drawerOpen: boolean;
	pageCount: number;
	index: number;
	/** The content under the finger can still scroll sideways in this direction. */
	canScrollX: boolean;
	/** The row under the finger can be swiped away to the left. */
	canSwipe?: boolean;
}

/** What a horizontal drag moves. Decided once, when the drag locks. */
export function resolveDrag({
	dx,
	drawerOpen,
	pageCount,
	index,
	canScrollX,
	canSwipe = false
}: DragContext): DragKind {
	if (drawerOpen) return dx < 0 ? 'drawer-close' : 'none';
	if (canScrollX) return 'hscroll';
	if (dx > 0) return index > 0 ? 'page' : 'drawer-open';
	if (canSwipe) return 'swipe';
	return pageCount > 0 ? 'page' : 'none';
}

const RUBBER = 0.25;

/** The pager's pixel offset for a drag. Past the first or last page it resists. */
export function pageOffset(dx: number, index: number, pageCount: number): number {
	const hasNeighbour = dx > 0 ? index > 0 : index < pageCount - 1;
	return hasNeighbour ? dx : dx * RUBBER;
}

export const SETTLE_DISTANCE = 0.35;
/** Pixels per millisecond. */
export const SETTLE_VELOCITY = 0.5;

/** Whether a release at `dx` (with speed `vx`) carries on in its direction. */
function commits(dx: number, vx: number, width: number): -1 | 0 | 1 {
	if (Math.abs(vx) >= SETTLE_VELOCITY && Math.sign(vx) === Math.sign(dx)) return dx > 0 ? 1 : -1;
	if (Math.abs(dx) >= width * SETTLE_DISTANCE) return dx > 0 ? 1 : -1;
	return 0;
}

/** The page a released drag lands on. */
export function settlePage(
	dx: number,
	vx: number,
	index: number,
	pageCount: number,
	width: number
): number {
	const next = index - commits(dx, vx, width);
	return Math.min(Math.max(next, 0), Math.max(pageCount - 1, 0));
}

/** Whether a row released at `dx` (a left swipe is negative) is swiped away. */
export function settleSwipe(dx: number, vx: number, width: number): boolean {
	return dx < 0 && commits(dx, vx, width) === -1;
}

/** Whether the drawer ends open after a drag released at `progress` (0 to 1). */
export function settleDrawer(progress: number, vx: number, wasOpen: boolean): boolean {
	if (Math.abs(vx) >= SETTLE_VELOCITY) return vx > 0;
	return wasOpen ? progress > 1 - SETTLE_DISTANCE : progress >= SETTLE_DISTANCE;
}

export function clamp(value: number, min: number, max: number): number {
	return Math.min(Math.max(value, min), max);
}
