import { flushSync, untrack } from 'svelte';
import {
	clamp,
	pageOffset,
	resolveDrag,
	settleBack,
	resolveSheetDrag,
	settleDrawer,
	settlePage,
	settleSheet,
	settleSwipe,
	type DragKind,
	type SheetStop
} from './pager';

import { anchorScroll, pinchSize } from './textsize';
import { text } from './textsize.svelte';

const SLOP = 10;
/** Two taps this close in time and place are a double tap. */
const TAP_MS = 300;
const TAP_PX = 30;
const PULL_TRIGGER = 56;
const PULL_MAX = 96;
const PULL_HOLD = 44;
/** A swipe up this far on a thread that is at its end brings the board up. */
const RISE = 24;

/** What the gestures move. Views read it; visible controls call its methods. */
class Ui {
	/** How far the sidebar is open: 0 closed, 1 open. Between them mid-drag. */
	drawer = $state(0);
	/** A finger is moving the drawer or the pager, so nothing animates. */
	dragging = $state(false);
	/** The pages of the current view, left to right. Empty on a view with none. */
	pages = $state.raw<string[]>([]);
	index = $state(0);
	/** Pixel offset of the pager while it follows a finger. */
	dragX = $state(0);
	/**
	 * Closes what the current page has open over its own list (a file). While
	 * it is set, a right swipe does that before it changes the page.
	 */
	back = $state.raw<(() => void) | null>(null);
	/** Pixel offset of that open layer while it follows a finger. */
	backX = $state(0);
	/** Called with the page the pager settles on or is sent to. */
	private landed: ((index: number) => void) | null = null;
	/** The scroller being pulled down, how far, and whether a finger holds it. */
	pullKey = $state<string | null>(null);
	pull = $state(0);
	pulling = $state(false);
	refreshing = $state<string | null>(null);
	/**
	 * The board drawer: its stop, how much of the board each stop shows, and a
	 * drag in progress. The footer is its top edge; the board is below it.
	 */
	sheet = $state<SheetStop>(0);
	sheetHeights = $state.raw<[number, number, number]>([0, 250, 560]);
	/** How far above its stop a finger holds the drawer, in pixels. */
	sheetUp = $state(0);
	sheetDragging = $state(false);
	/** The text box has the keyboard: the footer sits on it and the board stays shut. */
	sheetLocked = $state(false);

	/** The grabber: one stop up, and from the top back to rest. */
	stepSheet(): void {
		if (this.sheetLocked) return;
		this.sheet = this.sheet === 2 ? 0 : ((this.sheet + 1) as SheetStop);
	}

	/** The thread was swiped up at its end: bring the board up from rest. */
	riseSheet(): void {
		if (this.sheet === 0 && !this.sheetLocked) this.sheet = 1;
	}

	/** The text box took or lost the keyboard. */
	lockSheet(locked: boolean): void {
		this.sheetLocked = locked;
		if (locked) {
			this.sheet = 0;
			this.sheetUp = 0;
		}
	}

	get drawerOpen(): boolean {
		return this.drawer === 1;
	}

	openDrawer(): void {
		this.drawer = 1;
	}

	closeDrawer(): void {
		this.drawer = 0;
	}

	setPages(pages: string[], landed: ((index: number) => void) | null = null): void {
		this.pages = pages;
		this.landed = landed;
		this.index = clamp(this.index, 0, Math.max(pages.length - 1, 0));
		this.dragX = 0;
		this.backX = 0;
	}

	goTo(index: number): void {
		const next = clamp(index, 0, Math.max(this.pages.length - 1, 0));
		const moved = next !== this.index;
		this.index = next;
		if (moved) this.landed?.(next);
	}

	/** Run the refresh a scroller registered, with the indicator held open. */
	async refresh(key: string): Promise<void> {
		if (this.refreshing) return;
		this.refreshing = key;
		this.pullKey = key;
		this.pull = PULL_HOLD;
		try {
			await refreshers[key]?.();
		} finally {
			this.refreshing = null;
			this.pull = 0;
		}
	}
}

export const ui = new Ui();

/** What a pull on each `data-pull` scroller reloads. */
const refreshers: Record<string, (() => Promise<void>) | undefined> = {};

/** Attachment for a `data-pull="<key>"` scroller: says what a pull reloads. */
export function pullToRefresh(key: string, run: () => Promise<void>): () => () => void {
	return () => {
		refreshers[key] = run;
		return () => {
			if (refreshers[key] === run) delete refreshers[key];
		};
	};
}

/**
 * Attachment for a pager: declares the view's pages while it is mounted.
 * `landed` hears each change of page, by swipe or by tab.
 */
export function pages(keys: string[], landed?: (index: number) => void): () => () => void {
	return () => {
		untrack(() => ui.setPages(keys, landed));
		return () => untrack(() => ui.setPages([]));
	};
}

/** What a left swipe on each `data-swipe` row does once it is swiped away. */
const swipes = new WeakMap<Element, () => void>();

/**
 * Attachment for a row a left swipe removes. The row follows the finger; past
 * the settle point `away` runs. The row needs a visible control that does the
 * same.
 */
export function swipeAway(away: () => void): (node: HTMLElement) => () => void {
	return (node) => {
		node.dataset.swipe = '';
		swipes.set(node, away);
		return () => swipes.delete(node);
	};
}

function canScroll(el: HTMLElement | null, dx: number): boolean {
	if (!el) return false;
	const max = el.scrollWidth - el.clientWidth;
	return dx > 0 ? el.scrollLeft > 0 : el.scrollLeft < max - 1;
}

/**
 * Attachment for the app root. Horizontal drags use Pointer Events (the root
 * has `touch-action: pan-y`, so the browser keeps vertical scrolling and hands
 * us the rest). Pull-to-refresh uses Touch Events, because it has to stop the
 * browser's own overscroll on the first move.
 */
export function gestures(node: HTMLElement): () => void {
	let start: { id: number; x: number; y: number } | null = null;
	let kind: DragKind | 'vertical' | 'sheet' | 'sheet-list' | null = null;
	let sheetList: HTMLElement | null = null;
	let onSheet = false;
	let listStart = 0;
	let lastY = 0;
	let vy = 0;
	let base = 0;
	let lastX = 0;
	let lastT = 0;
	let vx = 0;
	let hscroll: HTMLElement | null = null;
	let hscrollStart = 0;
	let swiped: HTMLElement | null = null;
	let origin: Element | null = null;
	let momentum = 0;
	let suppressClick = false;
	let downT = 0;
	let downZoom = false;
	/** More than one finger has been down since the first one landed. */
	let multi = false;
	let lastTap: { t: number; x: number; y: number } | null = null;

	const drawerWidth = (): number =>
		node.querySelector<HTMLElement>('[data-drawer]')?.offsetWidth ?? node.clientWidth * 0.86;

	function onPointerDown(event: PointerEvent): void {
		suppressClick = false;
		cancelAnimationFrame(momentum);
		if (!event.isPrimary || (event.pointerType === 'mouse' && event.button !== 0)) return;
		start = { id: event.pointerId, x: event.clientX, y: event.clientY };
		kind = null;
		vx = 0;
		lastX = event.clientX;
		lastT = event.timeStamp;
		downT = event.timeStamp;
		downZoom = (event.target as Element).closest('[data-zoom]') !== null;
		hscroll = (event.target as Element).closest<HTMLElement>('[data-hscroll]');
		swiped = (event.target as Element).closest<HTMLElement>('[data-swipe]');
		origin = event.target as Element;
		// A drag that begins in the text box is typing or moving the caret, not the drawer.
		onSheet =
			!ui.sheetLocked &&
			(event.target as Element).closest('[data-sheet]') !== null &&
			(event.target as Element).closest('input, textarea') === null;
		sheetList = (event.target as Element).closest<HTMLElement>('[data-sheet-list]');
		lastY = event.clientY;
		vy = 0;
	}

	/** Let go of the drag with nothing moved. */
	function abandon(): void {
		ui.dragX = 0;
		ui.backX = 0;
		if (kind === 'drawer-open') ui.drawer = 0;
		else if (kind === 'drawer-close') ui.drawer = 1;
		ui.dragging = false;
		start = null;
		kind = null;
	}

	/** Undo a drag that is under way, as if the finger had never moved. */
	function cancelDrag(): void {
		if (kind === 'drawer-open') ui.drawer = 0;
		else if (kind === 'drawer-close') ui.drawer = 1;
		else if (kind === 'page') ui.dragX = 0;
		else if (kind === 'sheet') ui.sheetUp = 0;
		if (start) kind = 'none';
		ui.dragging = false;
		ui.sheetDragging = false;
	}

	/** Two quick taps on zoomable text put it back to the default size. */
	function noteTap(event: PointerEvent): void {
		const tap = { t: event.timeStamp, x: event.clientX, y: event.clientY };
		const double =
			lastTap !== null &&
			tap.t - lastTap.t <= TAP_MS &&
			Math.hypot(tap.x - lastTap.x, tap.y - lastTap.y) <= TAP_PX;
		lastTap = double ? null : tap;
		if (double) text.reset();
	}

	function onPointerMove(event: PointerEvent): void {
		if (!start || event.pointerId !== start.id) return;
		// A zoomed or pinched image owns the touch: it pans, nothing pages.
		if (origin?.closest('[data-nopage]')) return abandon();
		const dx = event.clientX - start.x;
		const dy = event.clientY - start.y;
		if (kind === null) {
			if (multi) return;
			if (Math.max(Math.abs(dx), Math.abs(dy)) < SLOP) return;
			if (Math.abs(dy) > Math.abs(dx)) {
				// The board drawer is the one thing a vertical drag moves; all
				// other vertical movement is the browser's scrolling.
				if (!onSheet || ui.drawer > 0) {
					kind = 'vertical';
					return;
				}
				kind = resolveSheetDrag({
					stop: ui.sheet,
					dy,
					inList: sheetList !== null,
					listTop: sheetList?.scrollTop ?? 0
				});
				base = dy;
				listStart = sheetList?.scrollTop ?? 0;
				node.setPointerCapture(start.id);
				if (kind === 'sheet') ui.sheetDragging = true;
			}
		}
		if (kind === 'sheet' || kind === 'sheet-list') {
			const dt = event.timeStamp - lastT;
			if (dt > 0) vy = 0.7 * ((event.clientY - lastY) / dt) + 0.3 * vy;
			lastY = event.clientY;
			lastT = event.timeStamp;
			const up = base - dy;
			if (kind === 'sheet') ui.sheetUp = up;
			else if (sheetList) sheetList.scrollTop = listStart + up;
			return;
		}
		if (kind === null) {
			// The Maestro panel lies over the page: a drag in it opens the sidebar
			// or swipes a card, and never turns the page under it.
			const over = origin?.closest('[data-maestro-panel]') != null;
			kind = resolveDrag({
				dx,
				drawerOpen: ui.drawerOpen,
				pageCount: over ? 0 : ui.pages.length,
				index: over ? 0 : ui.index,
				canScrollX: canScroll(hscroll, dx),
				canSwipe: swiped !== null,
				canBack: !over && ui.back !== null
			});
			if (kind === 'none') return;
			base = dx;
			hscrollStart = hscroll?.scrollLeft ?? 0;
			node.setPointerCapture(start.id);
			if (kind === 'swipe') swiped?.style.setProperty('transition', 'none');
			else if (kind !== 'hscroll') ui.dragging = true;
		}
		if (kind === 'vertical' || kind === 'none') return;

		const dt = event.timeStamp - lastT;
		if (dt > 0) vx = 0.7 * ((event.clientX - lastX) / dt) + 0.3 * vx;
		lastX = event.clientX;
		lastT = event.timeStamp;

		const moved = dx - base;
		if (kind === 'drawer-open') ui.drawer = clamp(moved / drawerWidth(), 0, 1);
		else if (kind === 'drawer-close') ui.drawer = clamp(1 + moved / drawerWidth(), 0, 1);
		else if (kind === 'page') ui.dragX = pageOffset(moved, ui.index, ui.pages.length);
		else if (kind === 'back') ui.backX = Math.max(moved, 0);
		else if (kind === 'swipe')
			swiped?.style.setProperty('transform', `translateX(${Math.min(moved, 0)}px)`);
		else if (hscroll) hscroll.scrollLeft = hscrollStart - moved;
	}

	function coast(
		el: HTMLElement,
		velocity: number,
		axis: 'scrollLeft' | 'scrollTop' = 'scrollLeft'
	): void {
		let v = velocity;
		let previous = performance.now();
		const step = (now: number): void => {
			el[axis] -= v * (now - previous);
			previous = now;
			v *= 0.94;
			if (Math.abs(v) > 0.02) momentum = requestAnimationFrame(step);
		};
		momentum = requestAnimationFrame(step);
	}

	function onPointerEnd(event: PointerEvent): void {
		if (!start || event.pointerId !== start.id) return;
		const tapped =
			event.type === 'pointerup' && kind === null && !multi && event.timeStamp - downT <= TAP_MS;
		if (tapped && downZoom) noteTap(event);
		else lastTap = null;
		const still = event.type === 'pointercancel' || event.timeStamp - lastT > 80;
		if (kind === 'sheet') {
			const stop = settleSheet(ui.sheet, ui.sheetUp, still ? 0 : vy);
			// Below the tall stop the list does not scroll: it starts from its top.
			if (stop < 2) node.querySelector('[data-sheet-list]')?.scrollTo({ top: 0 });
			ui.sheet = stop;
			ui.sheetUp = 0;
			ui.sheetDragging = false;
		} else if (kind === 'sheet-list' && sheetList && !still && Math.abs(vy) > 0.1) {
			coast(sheetList, vy, 'scrollTop');
		}
		const moved = event.clientX - start.x - base;
		const speed = still ? 0 : vx;
		if (kind === 'drawer-open' || kind === 'drawer-close') {
			ui.drawer = settleDrawer(ui.drawer, speed, kind === 'drawer-close') ? 1 : 0;
		} else if (kind === 'page') {
			ui.goTo(settlePage(moved, speed, ui.index, ui.pages.length, node.clientWidth));
			ui.dragX = 0;
		} else if (kind === 'back') {
			if (settleBack(moved, speed, node.clientWidth)) ui.back?.();
			ui.backX = 0;
		} else if (kind === 'hscroll' && hscroll && Math.abs(speed) > 0.1) {
			coast(hscroll, speed);
		} else if (kind === 'swipe' && swiped) {
			swiped.style.removeProperty('transition');
			if (settleSwipe(moved, speed, swiped.offsetWidth)) {
				swiped.style.setProperty('transform', 'translateX(-110%)');
				swipes.get(swiped)?.();
			} else {
				swiped.style.removeProperty('transform');
			}
		}
		suppressClick = kind !== null && kind !== 'vertical' && kind !== 'none';
		ui.dragging = false;
		start = null;
		kind = null;
	}

	// A drag that ends over a row or a button must not also tap it.
	function onClickCapture(event: MouseEvent): void {
		if (!suppressClick) return;
		suppressClick = false;
		event.preventDefault();
		event.stopPropagation();
	}

	let pull: { key: string; x: number; y: number; active: boolean } | null = null;
	/** A touch that began on a thread at its end: a swipe up there raises the board. */
	let rise: { x: number; y: number } | null = null;

	interface Axis {
		el: HTMLElement;
		scroll: number;
		mid: number;
		offset: number;
	}
	/** The element the fingers began on, and how far down it they were (0 to 1). */
	interface Held {
		scroller: HTMLElement;
		el: Element;
		at: number;
	}
	let pinch:
		| { size: number; distance: number; lineHeight: number; x: Axis; y: Axis }
		| { size: number; distance: number; held: Held }
		| null = null;

	const lineHeightOf = (el: HTMLElement): number => parseFloat(getComputedStyle(el).lineHeight);

	const spread = (touches: TouchList): number =>
		Math.hypot(touches[0].clientX - touches[1].clientX, touches[0].clientY - touches[1].clientY);
	const middle = (touches: TouchList): { x: number; y: number } => ({
		x: (touches[0].clientX + touches[1].clientX) / 2,
		y: (touches[0].clientY + touches[1].clientY) / 2
	});

	/** Two fingers on zoomable text: from here they change its size, nothing else. */
	function beginPinch(event: TouchEvent): boolean {
		const zoom = (event.touches[0].target as Element).closest<HTMLElement>('[data-zoom]');
		if (!zoom || !zoom.contains(event.touches[1].target as Node)) return false;
		cancelDrag();
		// Text that wraps (the chat) grows by more than its size, so no ratio places
		// it: the element under the fingers is held there instead.
		if (zoom.dataset.zoom === 'wrap') {
			const mid = middle(event.touches);
			const under = document.elementFromPoint(mid.x, mid.y);
			const el = under && zoom.contains(under) ? under : zoom;
			const box = el.getBoundingClientRect();
			cancelAnimationFrame(momentum);
			pinch = {
				size: text.size,
				distance: spread(event.touches),
				held: { scroller: zoom, el, at: box.height > 0 ? (mid.y - box.top) / box.height : 0 }
			};
			return true;
		}
		// The text scrolls down in `zoom` and sideways in its `data-hscroll` child.
		const wide = zoom.querySelector<HTMLElement>('[data-hscroll]') ?? zoom;
		const zoomBox = zoom.getBoundingClientRect();
		const wideBox = wide.getBoundingClientRect();
		const padding = getComputedStyle(wide);
		const mid = middle(event.touches);
		cancelAnimationFrame(momentum);
		pinch = {
			size: text.size,
			distance: spread(event.touches),
			lineHeight: lineHeightOf(wide),
			x: {
				el: wide,
				scroll: wide.scrollLeft,
				mid: mid.x - wideBox.left,
				offset: parseFloat(padding.paddingLeft)
			},
			y: {
				el: zoom,
				scroll: zoom.scrollTop,
				mid: mid.y - zoomBox.top,
				offset:
					wide === zoom
						? 0
						: wideBox.top - zoomBox.top + zoom.scrollTop + parseFloat(padding.paddingTop)
			}
		};
		return true;
	}

	function movePinch(event: TouchEvent): void {
		if (!pinch || event.touches.length < 2) return;
		text.preview(pinchSize(pinch.size, pinch.distance, spread(event.touches)));
		// Lay the text out at its new size now, so the scroll positions below hold.
		flushSync();
		const mid = middle(event.touches);
		if ('held' in pinch) {
			const { scroller, el, at } = pinch.held;
			// A message drawn again while it arrives is a new element: nothing to hold.
			if (!el.isConnected) return;
			const box = el.getBoundingClientRect();
			scroller.scrollTop += box.top + box.height * at - mid.y;
			return;
		}
		const ratio = text.size / pinch.size;
		const { x, y } = pinch;
		x.el.scrollLeft = anchorScroll({
			...x,
			ratio,
			midNow: mid.x - x.el.getBoundingClientRect().left
		});
		// Lines are a whole number of pixels tall, so they do not grow exactly as the text does.
		const lines = lineHeightOf(x.el) / pinch.lineHeight;
		y.el.scrollTop = anchorScroll({
			...y,
			ratio: Number.isFinite(lines) && lines > 0 ? lines : ratio,
			midNow: mid.y - y.el.getBoundingClientRect().top
		});
	}

	function onTouchStart(event: TouchEvent): void {
		multi = event.touches.length > 1;
		if (pull?.active) {
			ui.pulling = false;
			ui.pull = 0;
		}
		pull = null;
		if (event.touches.length === 2) {
			lastTap = null;
			// Two fingers are a pinch or nothing: the one left behind raises no board.
			rise = null;
			beginPinch(event);
			return;
		}
		rise = null;
		if (event.touches.length === 1) {
			const thread = (event.target as Element).closest<HTMLElement>('[data-rise]');
			if (thread && thread.scrollHeight - thread.scrollTop - thread.clientHeight < 2) {
				rise = { x: event.touches[0].clientX, y: event.touches[0].clientY };
			}
		}
		if (event.touches.length !== 1 || ui.refreshing) return;
		const scroller = (event.target as Element).closest<HTMLElement>('[data-pull]');
		if (!scroller || scroller.scrollTop > 0) return;
		const touch = event.touches[0];
		pull = { key: scroller.dataset.pull ?? '', x: touch.clientX, y: touch.clientY, active: false };
	}

	function onTouchMove(event: TouchEvent): void {
		if (pinch) {
			if (event.cancelable) event.preventDefault();
			movePinch(event);
			return;
		}
		if (rise) {
			const dx = event.touches[0].clientX - rise.x;
			const dy = event.touches[0].clientY - rise.y;
			if (dy > 0 || Math.abs(dx) > Math.abs(dy)) rise = null;
			else if (dy <= -RISE) {
				rise = null;
				ui.riseSheet();
			}
		}
		if (!pull) return;
		const touch = event.touches[0];
		const dx = touch.clientX - pull.x;
		const dy = touch.clientY - pull.y;
		if (!pull.active) {
			if (dy <= 0 || Math.abs(dx) > dy) {
				pull = null;
				return;
			}
			pull.active = true;
			ui.pullKey = pull.key;
			ui.pulling = true;
		}
		if (event.cancelable) event.preventDefault();
		ui.pull = clamp(dy * 0.5, 0, PULL_MAX);
	}

	function onTouchEnd(): void {
		// A pinch ends when either finger lifts; the one left does not start a drag.
		if (pinch) {
			pinch = null;
			text.save();
			return;
		}
		if (!pull?.active) {
			pull = null;
			return;
		}
		const { key } = pull;
		pull = null;
		ui.pulling = false;
		if (ui.pull >= PULL_TRIGGER) void ui.refresh(key);
		else ui.pull = 0;
	}

	// A mouse would otherwise start dragging a link, which cancels the pointer.
	const noNativeDrag = (event: DragEvent): void => event.preventDefault();

	// Safari's own pinch would zoom the whole page.
	const noPageZoom = (event: Event): void => event.preventDefault();

	node.addEventListener('gesturestart', noPageZoom);
	node.addEventListener('gesturechange', noPageZoom);
	node.addEventListener('dragstart', noNativeDrag);
	node.addEventListener('pointerdown', onPointerDown);
	node.addEventListener('pointermove', onPointerMove);
	node.addEventListener('pointerup', onPointerEnd);
	node.addEventListener('pointercancel', onPointerEnd);
	node.addEventListener('click', onClickCapture, true);
	node.addEventListener('touchstart', onTouchStart, { passive: true });
	node.addEventListener('touchmove', onTouchMove, { passive: false });
	node.addEventListener('touchend', onTouchEnd);
	node.addEventListener('touchcancel', onTouchEnd);

	return () => {
		cancelAnimationFrame(momentum);
		node.removeEventListener('gesturestart', noPageZoom);
		node.removeEventListener('gesturechange', noPageZoom);
		node.removeEventListener('dragstart', noNativeDrag);
		node.removeEventListener('pointerdown', onPointerDown);
		node.removeEventListener('pointermove', onPointerMove);
		node.removeEventListener('pointerup', onPointerEnd);
		node.removeEventListener('pointercancel', onPointerEnd);
		node.removeEventListener('click', onClickCapture, true);
		node.removeEventListener('touchstart', onTouchStart);
		node.removeEventListener('touchmove', onTouchMove);
		node.removeEventListener('touchend', onTouchEnd);
		node.removeEventListener('touchcancel', onTouchEnd);
	};
}
