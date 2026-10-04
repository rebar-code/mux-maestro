import { describe, expect, it } from 'vitest';
import {
	DOUBLE_TAP_MS,
	isTap,
	DOUBLE_TAP_SLOP,
	menuAfter,
	TAP_HOLD_MS,
	TAP_SLOP,
	type Tap
} from './doubletap';

const tap = (
	row: number | null,
	at: number,
	open: number | null = null,
	x = 100,
	y = 200
): Tap => ({
	row,
	x,
	y,
	at,
	open
});

describe('a touch that is a tap', () => {
	it('is short and stays where it began', () => {
		expect(isTap({ x: 10, y: 10, at: 0 }, { x: 12, y: 13, at: 90 })).toBe(true);
	});

	it('is not a finger that moved: that is a scroll', () => {
		expect(isTap({ x: 10, y: 10, at: 0 }, { x: 10, y: 10 + TAP_SLOP + 1, at: 90 })).toBe(false);
	});

	it('is not a long press: that selects text', () => {
		expect(isTap({ x: 10, y: 10, at: 0 }, { x: 10, y: 10, at: TAP_HOLD_MS + 1 })).toBe(false);
	});
});

describe('the menu under a message: a double tap', () => {
	it('opens on two taps of the same message in time', () => {
		expect(menuAfter(tap(4, 1000), tap(4, 1000 + DOUBLE_TAP_MS - 1))).toBe(4);
	});

	it('stays closed on one tap', () => {
		expect(menuAfter(null, tap(4, 1000))).toBe(null);
	});

	it('stays closed when the second tap is late', () => {
		expect(menuAfter(tap(4, 1000), tap(4, 1000 + DOUBLE_TAP_MS + 1))).toBe(null);
	});

	it('stays closed when the second tap is somewhere else on the message', () => {
		expect(menuAfter(tap(4, 1000), tap(4, 1100, null, 100, 200 + DOUBLE_TAP_SLOP + 1))).toBe(null);
	});

	it('stays closed when the taps are on two messages', () => {
		expect(menuAfter(tap(4, 1000), tap(6, 1100))).toBe(null);
	});

	it('stays closed for two taps on nothing', () => {
		expect(menuAfter(tap(null, 1000), tap(null, 1100))).toBe(null);
	});

	it('closes on a tap outside', () => {
		expect(menuAfter(null, tap(null, 1000, 4))).toBe(null);
		expect(menuAfter(null, tap(6, 1000, 4))).toBe(null);
	});

	it('closes on a second double tap of the message that has it', () => {
		// The first tap found the menu open.
		expect(menuAfter(tap(4, 1000, 4), tap(4, 1100))).toBe(null);
	});

	it('moves to another message that is double tapped', () => {
		expect(menuAfter(tap(6, 1000, 4), tap(6, 1100))).toBe(6);
	});
});
