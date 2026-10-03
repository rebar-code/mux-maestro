import { untrack } from 'svelte';
import {
	clamp,
	pageOffset,
	resolveDrag,
	settleDrawer,
	settlePage,
	settleSwipe,
	type DragKind
} from './pager';

const SLOP = 10;
const PULL_TRIGGER = 56;
const PULL_MAX = 96;
const PULL_HOLD = 44;

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
	/** The scroller being pulled down, how far, and whether a finger holds it. */
	pullKey = $state<string | null>(null);
	pull = $state(0);
	pulling = $state(false);
	refreshing = $state<string | null>(null);

	get drawerOpen(): boolean {
		return this.drawer === 1;
	}

	openDrawer(): void {
		this.drawer = 1;
	}

	closeDrawer(): void {
		this.drawer = 0;
	}

	setPages(pages: string[]): void {
		this.pages = pages;
		this.index = clamp(this.index, 0, Math.max(pages.length - 1, 0));
		this.dragX = 0;
	}

	goTo(index: number): void {
		this.index = clamp(index, 0, Math.max(this.pages.length - 1, 0));
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

/** Attachment for a pager: declares the view's pages while it is mounted. */
export function pages(keys: string[]): () => () => void {
	return () => {
		untrack(() => ui.setPages(keys));
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
	let kind: DragKind | 'vertical' | null = null;
	let base = 0;
	let lastX = 0;
	let lastT = 0;
	let vx = 0;
	let hscroll: HTMLElement | null = null;
	let hscrollStart = 0;
	let swiped: HTMLElement | null = null;
	let momentum = 0;
	let suppressClick = false;

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
		hscroll = (event.target as Element).closest<HTMLElement>('[data-hscroll]');
		swiped = (event.target as Element).closest<HTMLElement>('[data-swipe]');
	}

	function onPointerMove(event: PointerEvent): void {
		if (!start || event.pointerId !== start.id) return;
		const dx = event.clientX - start.x;
		const dy = event.clientY - start.y;
		if (kind === null) {
			if (Math.max(Math.abs(dx), Math.abs(dy)) < SLOP) return;
			if (Math.abs(dy) > Math.abs(dx)) {
				kind = 'vertical';
				return;
			}
			kind = resolveDrag({
				dx,
				drawerOpen: ui.drawerOpen,
				pageCount: ui.pages.length,
				index: ui.index,
				canScrollX: canScroll(hscroll, dx),
				canSwipe: swiped !== null
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
		else if (kind === 'swipe')
			swiped?.style.setProperty('transform', `translateX(${Math.min(moved, 0)}px)`);
		else if (hscroll) hscroll.scrollLeft = hscrollStart - moved;
	}

	function coast(el: HTMLElement, velocity: number): void {
		let v = velocity;
		let previous = performance.now();
		const step = (now: number): void => {
			el.scrollLeft -= v * (now - previous);
			previous = now;
			v *= 0.94;
			if (Math.abs(v) > 0.02) momentum = requestAnimationFrame(step);
		};
		momentum = requestAnimationFrame(step);
	}

	function onPointerEnd(event: PointerEvent): void {
		if (!start || event.pointerId !== start.id) return;
		const moved = event.clientX - start.x - base;
		const speed = event.type === 'pointercancel' || event.timeStamp - lastT > 80 ? 0 : vx;
		if (kind === 'drawer-open' || kind === 'drawer-close') {
			ui.drawer = settleDrawer(ui.drawer, speed, kind === 'drawer-close') ? 1 : 0;
		} else if (kind === 'page') {
			ui.index = settlePage(moved, speed, ui.index, ui.pages.length, node.clientWidth);
			ui.dragX = 0;
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

	function onTouchStart(event: TouchEvent): void {
		pull = null;
		if (event.touches.length !== 1 || ui.refreshing) return;
		const scroller = (event.target as Element).closest<HTMLElement>('[data-pull]');
		if (!scroller || scroller.scrollTop > 0) return;
		const touch = event.touches[0];
		pull = { key: scroller.dataset.pull ?? '', x: touch.clientX, y: touch.clientY, active: false };
	}

	function onTouchMove(event: TouchEvent): void {
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
