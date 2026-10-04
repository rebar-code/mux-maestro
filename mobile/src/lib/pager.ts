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

/** The board sheet's stops: rest (a peek), open, tall. */
export type SheetStop = 0 | 1 | 2;

/** What a vertical drag that began on the sheet moves: the sheet or its list. */
export function resolveSheetDrag(context: {
	stop: SheetStop;
	/** Finger movement so far: negative is a swipe up. */
	dy: number;
	/** The drag began on the sheet's list. */
	inList: boolean;
	/** How far the list is scrolled from its top. */
	listTop: number;
}): 'sheet' | 'sheet-list' {
	// The list scrolls only at the tall stop. There a swipe up reads on, and a
	// swipe down scrolls back to the top first; from the top it moves the sheet.
	if (context.stop === 2 && context.inList && (context.dy < 0 || context.listTop > 0)) {
		return 'sheet-list';
	}
	return 'sheet';
}

/** The sheet's height while a finger holds it, `up` pixels above where it rested. */
export function sheetHeight(heights: readonly number[], stop: SheetStop, up: number): number {
	const [rest, , tall] = heights;
	const wanted = heights[stop] + up;
	if (wanted > tall) return tall + (wanted - tall) * RUBBER;
	if (wanted < rest) return rest - (rest - wanted) * RUBBER;
	return wanted;
}

/** How far a drag must go to change the stop. */
export const SHEET_STEP = 28;

/** The stop a released drag lands on: one step per swipe. `vy` is negative going up. */
export function settleSheet(stop: SheetStop, up: number, vy: number): SheetStop {
	const flick = Math.abs(vy) >= SETTLE_VELOCITY;
	if (flick ? vy < 0 : up >= SHEET_STEP) return Math.min(stop + 1, 2) as SheetStop;
	if (flick ? vy > 0 : up <= -SHEET_STEP) return Math.max(stop - 1, 0) as SheetStop;
	return stop;
}

/** The sheet's three heights for a stage this tall, on a screen this tall. */
export function sheetStops(stage: number, viewport: number): [number, number, number] {
	const rest = 46;
	const tall = Math.max(rest, Math.min(Math.round(viewport * 0.7), stage - 8));
	const open = Math.max(rest, Math.min(Math.round(stage * 0.45), tall));
	return [rest, open, tall];
}
