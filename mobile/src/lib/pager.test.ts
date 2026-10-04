import { describe, expect, it } from 'vitest';
import { pageOffset, resolveDrag, settleDrawer, settlePage } from './pager';

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
