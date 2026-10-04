/**
 * The menu under a message: a double tap on the message opens it. The taps
 * are timed here, not left to `dblclick`: an installed web app on iOS does
 * not send that event reliably.
 */

export const DOUBLE_TAP_MS = 300;
/** How far a finger may move and still tap. Past it, it scrolls. */
export const TAP_SLOP = 10;
/** How long a finger may stay down and still tap. Past it, it selects text. */
export const TAP_HOLD_MS = 450;
/** How far the second tap may land from the first. */
export const DOUBLE_TAP_SLOP = 30;

interface Point {
	x: number;
	y: number;
	at: number;
}

/** One tap: the message row it was on (null: on none), and the menu that was open before it. */
export interface Tap extends Point {
	row: number | null;
	open: number | null;
}

export const isTap = (down: Point, up: Point): boolean =>
	up.at - down.at <= TAP_HOLD_MS && Math.hypot(up.x - down.x, up.y - down.y) <= TAP_SLOP;

/** `tap` is the second of two quick taps on one message. */
export const isDouble = (last: Tap | null, tap: Tap): boolean =>
	last !== null &&
	tap.row !== null &&
	last.row === tap.row &&
	tap.at - last.at <= DOUBLE_TAP_MS &&
	Math.hypot(tap.x - last.x, tap.y - last.y) <= DOUBLE_TAP_SLOP;

/**
 * The row whose menu is open after `tap`, which was not on a menu; `last` is
 * the tap before it. One tap closes the menu, wherever it lands. Two on one
 * message open that message's menu, unless it had it open: then they close it.
 */
export function menuAfter(last: Tap | null, tap: Tap): number | null {
	return isDouble(last, tap) && last?.open !== tap.row ? tap.row : null;
}

/** A link, a button or a file chip inside a message: a tap there is its own. */
const OWN = 'a, button, [role="link"], [data-local], [data-file], [data-img]';

/**
 * Attachment for the element that holds the messages. A message is a
 * `data-row` element, its menu a `data-menu` element. It only watches the
 * touches: a scroll, a pinch and a long press go where they went before.
 */
export function messageMenu(
	open: () => number | null,
	set: (row: number | null) => void
): (node: HTMLElement) => () => void {
	return (node) => {
		const page = node.ownerDocument;
		let down: (Point & { id: number; on: Element }) | null = null;
		let last: Tap | null = null;
		/** The touch that just ended was the second tap: it must not also be a click. */
		let eat = false;
		/** A tap on a message waits to close the menu: the page must not move under a second tap. */
		let closing: ReturnType<typeof setTimeout> | null = null;

		const settle = (): void => {
			if (closing) clearTimeout(closing);
			closing = null;
		};

		const rowOf = (target: Element): number | null => {
			if (!node.contains(target) || target.closest(OWN)) return null;
			const row = target.closest<HTMLElement>('[data-row]')?.dataset.row;
			return row === undefined ? null : Number(row);
		};

		const onDown = (event: PointerEvent): void => {
			eat = false;
			// A second finger is a pinch, another button is a menu of the browser.
			const first = event.isPrimary && (event.pointerType !== 'mouse' || event.button === 0);
			down = first
				? {
						id: event.pointerId,
						on: event.target as Element,
						x: event.clientX,
						y: event.clientY,
						at: event.timeStamp
					}
				: null;
			if (!first) last = null;
		};

		const onUp = (event: PointerEvent): void => {
			const began = down;
			down = null;
			if (began?.id !== event.pointerId) return;
			const up = { x: event.clientX, y: event.clientY, at: event.timeStamp };
			// Where it began: a captured pointer ends on the element that holds it.
			const target = began.on;
			if (!isTap(began, up) || target.closest('[data-menu]')) {
				last = null;
				return;
			}
			const tap = { ...up, row: rowOf(target), open: open() };
			const double = isDouble(last, tap);
			const next = menuAfter(last, tap);
			// Three taps are a double tap and one tap, not two double taps.
			last = double ? null : tap;
			settle();
			if (!double && tap.row !== null && tap.open !== null) {
				closing = setTimeout(() => set(null), DOUBLE_TAP_MS);
			} else if (next !== tap.open) {
				set(next);
			}
			if (!double) return;
			eat = event.pointerType === 'touch';
			page.getSelection()?.removeAllRanges();
		};

		const onCancel = (): void => {
			down = null;
			last = null;
		};

		// The second tap does not zoom the page or select the word under it.
		const onTouchEnd = (event: TouchEvent): void => {
			if (eat && event.cancelable) event.preventDefault();
			eat = false;
		};
		const onMouseDown = (event: MouseEvent): void => {
			if (event.detail > 1 && rowOf(event.target as Element) !== null) event.preventDefault();
		};

		// On the page: a tap outside the messages closes the menu too.
		page.addEventListener('pointerdown', onDown, true);
		page.addEventListener('pointerup', onUp, true);
		page.addEventListener('pointercancel', onCancel, true);
		node.addEventListener('touchend', onTouchEnd);
		node.addEventListener('mousedown', onMouseDown);
		return () => {
			settle();
			page.removeEventListener('pointerdown', onDown, true);
			page.removeEventListener('pointerup', onUp, true);
			page.removeEventListener('pointercancel', onCancel, true);
			node.removeEventListener('touchend', onTouchEnd);
			node.removeEventListener('mousedown', onMouseDown);
		};
	};
}
