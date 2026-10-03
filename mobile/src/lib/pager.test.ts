import { describe, expect, it } from 'vitest';
import {
	pageOffset,
	resolveDrag,
	settleBack,
	settleDrawer,
	settlePage,
	settleSwipe,
	type DragKind
} from './pager';

const base = { drawerOpen: false, pageCount: 3, index: 0, canScrollX: false };

describe('resolveDrag', () => {
	it('opens the drawer on a right swipe from the first page only', () => {
		expect(resolveDrag({ ...base, dx: 12 })).toBe('drawer-open');
		expect(resolveDrag({ ...base, dx: 12, index: 1 })).toBe('page');
		expect(resolveDrag({ ...base, dx: 12, index: 2 })).toBe('page');
	});

	it('moves between pages on a left swipe', () => {
		expect(resolveDrag({ ...base, dx: -12 })).toBe('page');
		expect(resolveDrag({ ...base, dx: -12, index: 2 })).toBe('page');
	});

	it('opens the drawer from a view with no pages, and ignores a left swipe there', () => {
		expect(resolveDrag({ ...base, pageCount: 0, dx: 12 })).toBe('drawer-open');
		expect(resolveDrag({ ...base, pageCount: 0, dx: -12 })).toBe('none');
	});

	it('lets sideways-scrolling content move first', () => {
		expect(resolveDrag({ ...base, dx: 12, canScrollX: true })).toBe('hscroll');
		expect(resolveDrag({ ...base, dx: -12, canScrollX: true })).toBe('hscroll');
	});

	it('only closes an open drawer', () => {
		expect(resolveDrag({ ...base, drawerOpen: true, dx: -12 })).toBe('drawer-close');
		expect(resolveDrag({ ...base, drawerOpen: true, dx: 12 })).toBe('none');
		expect(resolveDrag({ ...base, drawerOpen: true, dx: -12, canScrollX: true })).toBe(
			'drawer-close'
		);
	});
});

describe('swipe away', () => {
	it('a left swipe on a row that can go takes the row, not a page', () => {
		expect(resolveDrag({ ...base, pageCount: 0, dx: -12, canSwipe: true })).toBe('swipe');
		// A right swipe there still opens the drawer.
		expect(resolveDrag({ ...base, pageCount: 0, dx: 12, canSwipe: true })).toBe('drawer-open');
		expect(resolveDrag({ ...base, drawerOpen: true, dx: -12, canSwipe: true })).toBe(
			'drawer-close'
		);
	});

	it('goes after a long drag or a flick, and springs back otherwise', () => {
		expect(settleSwipe(-200, 0, 360)).toBe(true);
		expect(settleSwipe(-40, -0.8, 360)).toBe(true);
		expect(settleSwipe(-40, 0, 360)).toBe(false);
		expect(settleSwipe(-200, 0.8, 360)).toBe(true);
		expect(settleSwipe(0, 0, 360)).toBe(false);
	});
});

describe('pageOffset', () => {
	it('follows the finger when there is a page that way', () => {
		expect(pageOffset(-80, 0, 3)).toBe(-80);
		expect(pageOffset(80, 1, 3)).toBe(80);
	});

	it('resists past the last page and with a single page', () => {
		expect(pageOffset(-80, 2, 3)).toBe(-20);
		expect(pageOffset(-80, 0, 1)).toBe(-20);
	});
});

describe('settlePage', () => {
	const width = 390;

	it('moves one page after a long drag', () => {
		expect(settlePage(-200, 0, 0, 3, width)).toBe(1);
		expect(settlePage(-200, 0, 1, 3, width)).toBe(2);
		expect(settlePage(200, 0, 2, 3, width)).toBe(1);
	});

	it('moves one page after a short, fast flick', () => {
		expect(settlePage(-40, -0.9, 0, 3, width)).toBe(1);
		expect(settlePage(40, 0.9, 1, 3, width)).toBe(0);
	});

	it('springs back after a short, slow drag', () => {
		expect(settlePage(-60, -0.1, 1, 3, width)).toBe(1);
	});

	it('ignores a flick against the drag', () => {
		expect(settlePage(-60, 0.9, 1, 3, width)).toBe(1);
	});

	it('never leaves the row of pages', () => {
		expect(settlePage(-300, -2, 2, 3, width)).toBe(2);
		expect(settlePage(300, 2, 0, 3, width)).toBe(0);
		expect(settlePage(-300, -2, 0, 1, width)).toBe(0);
	});
});

describe('settleDrawer', () => {
	it('opens past the distance or on a right flick', () => {
		expect(settleDrawer(0.4, 0, false)).toBe(true);
		expect(settleDrawer(0.2, 0, false)).toBe(false);
		expect(settleDrawer(0.1, 0.8, false)).toBe(true);
	});

	it('closes past the distance or on a left flick', () => {
		expect(settleDrawer(0.6, 0, true)).toBe(false);
		expect(settleDrawer(0.8, 0, true)).toBe(true);
		expect(settleDrawer(0.9, -0.8, true)).toBe(false);
	});
});

describe('the thread tabs: Chat, Artifacts, Servers', () => {
	const width = 390;
	const tabs = { drawerOpen: false, pageCount: 3, canScrollX: false };

	/** One finished swipe: what moved, and where the view is after it. */
	function swipe(
		dx: number,
		state: { index: number; file: boolean }
	): { kind: DragKind; index: number; file: boolean; drawer: boolean } {
		const kind = resolveDrag({ ...tabs, dx, index: state.index, canBack: state.file });
		const next = { ...state, kind, drawer: false };
		if (kind === 'page') next.index = settlePage(dx, 0, state.index, tabs.pageCount, width);
		else if (kind === 'back') next.file = !settleBack(dx, 0, width);
		else if (kind === 'drawer-open') next.drawer = settleDrawer(dx / width, 0, false);
		return next;
	}

	it('a left swipe goes Chat, Artifacts, Servers and stops there', () => {
		let at = swipe(-200, { index: 0, file: false });
		expect(at).toMatchObject({ kind: 'page', index: 1 });
		at = swipe(-200, at);
		expect(at).toMatchObject({ kind: 'page', index: 2 });
		at = swipe(-200, at);
		expect(at).toMatchObject({ kind: 'page', index: 2, drawer: false });
	});

	it('a right swipe goes back one tab, then opens the sidebar from Chat', () => {
		let at = swipe(200, { index: 2, file: false });
		expect(at).toMatchObject({ kind: 'page', index: 1, drawer: false });
		at = swipe(200, at);
		expect(at).toMatchObject({ kind: 'page', index: 0, drawer: false });
		at = swipe(200, at);
		expect(at).toMatchObject({ kind: 'drawer-open', index: 0, drawer: true });
	});

	it('in an open file a right swipe goes to the file list first, then to Chat', () => {
		let at = swipe(200, { index: 1, file: true });
		expect(at).toMatchObject({ kind: 'back', index: 1, file: false });
		at = swipe(200, at);
		expect(at).toMatchObject({ kind: 'page', index: 0, file: false });
	});

	it('a short right swipe in an open file keeps the file', () => {
		expect(swipe(60, { index: 1, file: true })).toMatchObject({
			kind: 'back',
			index: 1,
			file: true
		});
		expect(settleBack(60, 0.9, width)).toBe(true);
		expect(settleBack(-200, -0.9, width)).toBe(false);
	});

	it('a left swipe in an open file still goes on to Servers', () => {
		expect(swipe(-200, { index: 1, file: true })).toMatchObject({
			kind: 'page',
			index: 2,
			file: true
		});
	});

	it('sideways-scrolling code or terminal text moves before any tab does', () => {
		for (const index of [0, 1, 2]) {
			for (const dx of [-12, 12]) {
				expect(resolveDrag({ ...tabs, dx, index, canScrollX: true, canBack: true })).toBe(
					'hscroll'
				);
			}
		}
	});

	it('an open sidebar only closes', () => {
		expect(resolveDrag({ ...tabs, dx: 12, index: 1, drawerOpen: true, canBack: true })).toBe(
			'none'
		);
	});
});
