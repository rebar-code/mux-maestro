/**
 * The math behind the horizontal gestures. The screen is an ordered row of
 * pages with the sidebar drawer one step left of page 0. Kept free of the DOM
 * so it is tested directly.
 */

export type DragKind =
	'drawer-open' | 'drawer-close' | 'page' | 'back' | 'hscroll' | 'swipe' | 'none';

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
	/** The page shows something opened from its own list: a right swipe closes that first. */
	canBack?: boolean;
}

/** What a horizontal drag moves. Decided once, when the drag locks. */
export function resolveDrag({
	dx,
	drawerOpen,
	pageCount,
	index,
	canScrollX,
	canSwipe = false,
	canBack = false
}: DragContext): DragKind {
	if (drawerOpen) return dx < 0 ? 'drawer-close' : 'none';
	if (canScrollX) return 'hscroll';
	if (dx > 0 && canBack) return 'back';
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

/** How far a finger pulls the messages down before the keyboard is put away. */
export const KEYBOARD_PULL = 24;

/**
 * Whether a drag on the messages puts the on-screen keyboard away: a pull
 * down (`dy` positive), more down than sideways. The page still scrolls under
 * the finger: the drag is not taken from the browser.
 */
export function pullsKeyboardDown(dx: number, dy: number): boolean {
	return dy >= KEYBOARD_PULL && dy > Math.abs(dx);
}

/** Whether a row released at `dx` (a left swipe is negative) is swiped away. */
export function settleSwipe(dx: number, vx: number, width: number): boolean {
	return dx < 0 && commits(dx, vx, width) === -1;
}

/** Whether a right swipe released at `dx` goes back. */
export function settleBack(dx: number, vx: number, width: number): boolean {
	return dx > 0 && commits(dx, vx, width) === 1;
}

/** Whether the drawer ends open after a drag released at `progress` (0 to 1). */
export function settleDrawer(progress: number, vx: number, wasOpen: boolean): boolean {
	if (Math.abs(vx) >= SETTLE_VELOCITY) return vx > 0;
	return wasOpen ? progress > 1 - SETTLE_DISTANCE : progress >= SETTLE_DISTANCE;
}

export function clamp(value: number, min: number, max: number): number {
	return Math.min(Math.max(value, min), max);
}

/**
 * The board drawer's stops. The footer (the text box and its controls) is the
 * drawer's top edge and the board hangs below it: at rest the footer is at the
 * bottom of the screen and the board is off screen; open shows the first
 * cards; tall gives the board most of the screen.
 */
export type SheetStop = 0 | 1 | 2;

/** What a vertical drag that began on the drawer moves: the drawer or the board's list. */
export function resolveSheetDrag(context: {
	stop: SheetStop;
	/** Finger movement so far: negative is a swipe up. */
	dy: number;
	/** The drag began on the board's list, not on the footer. */
	inList: boolean;
	/** How far the list is scrolled from its top. */
	listTop: number;
}): 'sheet' | 'sheet-list' {
	// The list scrolls only at the tall stop. There a swipe up reads on, and a
	// swipe down scrolls back to the top first; from the top it moves the drawer.
	if (context.stop === 2 && context.inList && (context.dy < 0 || context.listTop > 0)) {
		return 'sheet-list';
	}
	return 'sheet';
}

/** How much of the board shows while a finger holds the drawer `up` pixels above its stop. */
export function sheetHeight(heights: readonly number[], stop: SheetStop, up: number): number {
	const tall = heights[2];
	const wanted = heights[stop] + up;
	// Past the tall stop it resists; below rest there is nothing to pull.
	if (wanted > tall) return tall + (wanted - tall) * RUBBER;
	return Math.max(wanted, heights[0]);
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

/**
 * How much of the board shows at each stop. `room` is the height the thread
 * has at rest, which is all the footer can rise; `viewport` is the screen.
 */
export function sheetStops(room: number, viewport: number): [number, number, number] {
	const tall = Math.max(0, Math.min(Math.round(viewport * 0.7), Math.floor(room)));
	const open = Math.min(Math.round(viewport * 0.3), tall);
	return [0, open, tall];
}

/** Less than this of the screen lost is a toolbar, not a keyboard. */
const KEYBOARD_MIN = 120;

/**
 * The height an on-screen keyboard covers, from the layout height and the
 * visible height; 0 when there is none. The page is made that much shorter, so
 * its last row sits on the keyboard.
 */
export function keyboardInset(layout: number, visible: number): number {
	const covered = Math.round(layout - visible);
	return covered >= KEYBOARD_MIN ? covered : 0;
}

/** What the browser says about the page and the screen, in CSS pixels. */
export interface PageMeasure {
	/** The height the browser lays the page out at. */
	layout: number;
	/** The height of the visual viewport: what the keyboard leaves. */
	visible: number;
	/** How far the browser slid the visual viewport down the page. */
	slid: number;
	/** The height of the screen, as it is held now. */
	screen: number;
	/** Opened from the Home Screen, with no browser around the page. */
	standalone: boolean;
	/** The status bar's inset (`env(safe-area-inset-top)`). */
	safeTop: number;
}

export interface PageFit {
	/** What the page grows by to reach the bottom of the screen. */
	lift: number;
	/** What the keyboard takes off the grown page; 0 when there is none. */
	keyboard: number;
	/** How far down the page starts, while the keyboard is open. */
	slid: number;
}

/**
 * The size of the app root. A Home Screen app whose status bar is see-through
 * is drawn on the whole screen, yet an iPhone lays it out one status bar
 * shorter, which leaves an empty band under the last row: the page grows by
 * that much. Any other difference from the screen is a browser's own bars and
 * is left alone. With the keyboard open the page is exactly what is visible.
 */
export function pageFit(measure: PageMeasure): PageFit {
	const short = measure.screen - measure.layout;
	const lift =
		measure.standalone && short > 0 && Math.abs(short - measure.safeTop) <= 1 ? short : 0;
	const keyboard = keyboardInset(measure.layout + lift, measure.visible);
	return { lift, keyboard, slid: keyboard ? Math.max(0, measure.slid) : 0 };
}
