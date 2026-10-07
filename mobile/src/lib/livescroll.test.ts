import { describe, expect, it } from 'vitest';
import {
	fit,
	followTop,
	isFollowing,
	maxScroll,
	MAX_STEPS,
	place,
	totalHeight,
	wheelSteps,
	wheelText
} from './livescroll';

// 40 lines of 15 px (600 px of screen) seen through 300 px, with 100 lines above.
const g = { base: 100, rows: 40, cell: 15, view: 300 };

describe('the tall box', () => {
	it('is the scrollback and the screen', () => {
		expect(totalHeight(g)).toBe(2100);
		expect(maxScroll(g)).toBe(1800);
	});

	it('is at least the view when the screen is shorter', () => {
		const short = { base: 10, rows: 5, cell: 15, view: 300 };
		expect(totalHeight(short)).toBe(450);
		expect(maxScroll(short)).toBe(150);
		// The end still shows the newest screen.
		expect(place(150, short)).toEqual({ line: 10, shift: 0 });
	});
});

describe('place', () => {
	it('shows the end of the screen at the end of the box', () => {
		expect(place(1800, g)).toEqual({ line: 100, shift: 300 });
	});

	it('scrolls the screen itself before it reaches the scrollback', () => {
		expect(place(1650, g)).toEqual({ line: 100, shift: 150 });
		expect(place(1500, g)).toEqual({ line: 100, shift: 0 });
	});

	it('moves by pixels through the scrollback', () => {
		expect(place(1499, g)).toEqual({ line: 99, shift: 14 });
		expect(place(22, g)).toEqual({ line: 1, shift: 7 });
		expect(place(0, g)).toEqual({ line: 0, shift: 0 });
	});

	it('is continuous: one pixel of scroll is one pixel of text', () => {
		let last = -1;
		for (let top = 0; top <= maxScroll(g); top += 1) {
			const { line, shift } = place(top, g);
			const shown = line * g.cell + shift;
			expect(shown).toBe(top);
			expect(shown).toBeGreaterThan(last);
			last = shown;
		}
	});

	it('stays inside the box', () => {
		expect(place(-50, g)).toEqual({ line: 0, shift: 0 });
		expect(place(99999, g)).toEqual(place(1800, g));
		expect(place(10, { ...g, cell: 0 })).toEqual({ line: 0, shift: 0 });
	});
});

describe('following', () => {
	it('is the end when the cursor is near the end of the screen', () => {
		expect(followTop(g, 39)).toBe(1800);
		expect(followTop(g, 37)).toBe(1800);
	});

	it('keeps a cursor that is higher up in view', () => {
		// Line 5 of the screen, and two more: its bottom is at 1620 px.
		expect(followTop(g, 5)).toBe(1320);
		// The keyboard halves the view: the cursor is still in it.
		const half = { ...g, view: 150 };
		const top = followTop(half, 5);
		expect(top).toBe(1470);
		const { line, shift } = place(top, half);
		const cursorTop = (half.base + 5) * half.cell - (line * half.cell + shift);
		expect(cursorTop).toBeGreaterThanOrEqual(0);
		expect(cursorTop + half.cell).toBeLessThanOrEqual(half.view);
	});

	it('never scrolls before the start', () => {
		expect(followTop({ base: 0, rows: 40, cell: 15, view: 300 }, 0)).toBe(0);
	});

	it('knows when the view was moved away', () => {
		expect(isFollowing(1800, g, 39)).toBe(true);
		expect(isFollowing(1790, g, 39)).toBe(true);
		expect(isFollowing(1500, g, 39)).toBe(false);
	});
});

describe('a drag on a program that scrolls itself', () => {
	it('is one step for each line the finger travels', () => {
		expect(wheelSteps(0, 45, 15)).toEqual({ steps: 3, rest: 0 });
		expect(wheelSteps(0, -31, 15)).toEqual({ steps: -2, rest: -1 });
	});

	it('carries what is less than a line to the next move', () => {
		const first = wheelSteps(0, 10, 15);
		expect(first).toEqual({ steps: 0, rest: 10 });
		expect(wheelSteps(first.rest, 10, 15)).toEqual({ steps: 1, rest: 5 });
	});

	it('is capped for one move, and nothing without a line height', () => {
		expect(wheelSteps(0, 100000, 15)).toEqual({ steps: MAX_STEPS, rest: 0 });
		expect(wheelSteps(0, -100000, 15)).toEqual({ steps: -MAX_STEPS, rest: 0 });
		expect(wheelSteps(3, 40, 0)).toEqual({ steps: 0, rest: 0 });
	});

	it('is wheel reports when the program asked for the mouse: a finger going down scrolls up', () => {
		const at = { col: 7, row: 3 };
		expect(wheelText(2, { mouse: true, application: false }, at)).toBe(
			'\x1b[<64;7;3M\x1b[<64;7;3M'
		);
		expect(wheelText(-1, { mouse: true, application: false }, at)).toBe('\x1b[<65;7;3M');
	});

	it('is arrow keys when it did not, in the form the program asked for', () => {
		const at = { col: 1, row: 1 };
		expect(wheelText(2, { mouse: false, application: false }, at)).toBe('\x1b[A\x1b[A');
		expect(wheelText(-2, { mouse: false, application: true }, at)).toBe('\x1bOB\x1bOB');
		expect(wheelText(0, { mouse: true, application: false }, at)).toBe('');
	});

	it('names a cell that is whole and on the screen', () => {
		expect(wheelText(1, { mouse: true, application: false }, { col: 0, row: 2.7 })).toBe(
			'\x1b[<64;1;2M'
		);
	});
});

describe('the size the phone has room for', () => {
	it('is the cells that fit the view', () => {
		expect(fit({ width: 366, height: 600 }, { width: 9, height: 18 })).toEqual({
			cols: 40,
			rows: 33
		});
	});

	it('keeps to the limits the Mac allows', () => {
		expect(fit({ width: 90, height: 40 }, { width: 9, height: 18 })).toEqual({ cols: 20, rows: 5 });
		expect(fit({ width: 9000, height: 9000 }, { width: 2, height: 2 })).toEqual({
			cols: 300,
			rows: 200
		});
	});

	it('is nothing before the terminal is measured', () => {
		expect(fit({ width: 366, height: 600 }, { width: 0, height: 18 })).toBeNull();
		expect(fit({ width: 0, height: 0 }, { width: 9, height: 18 })).toBeNull();
		expect(fit({ width: 366, height: 600 }, { width: NaN, height: 18 })).toBeNull();
	});
});
