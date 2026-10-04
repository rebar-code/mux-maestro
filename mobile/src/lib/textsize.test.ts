import { describe, expect, it } from 'vitest';
import {
	anchorScroll,
	BOX_MIN,
	boxSize,
	chatSize,
	clampSize,
	DEFAULT_SIZE,
	MAX_SIZE,
	MIN_SIZE,
	pinchSize
} from './textsize';

describe('clampSize', () => {
	it('keeps a size between 6 and 24', () => {
		expect(clampSize(3)).toBe(6);
		expect(clampSize(6)).toBe(6);
		expect(clampSize(11)).toBe(11);
		expect(clampSize(24)).toBe(24);
		expect(clampSize(40)).toBe(24);
	});

	it('falls back to the default for a value that is not a number', () => {
		expect(clampSize(Number.NaN)).toBe(DEFAULT_SIZE);
	});
});

describe('pinchSize', () => {
	it('scales with the distance between the fingers', () => {
		expect(pinchSize(11, 100, 150)).toBe(16.5);
		expect(pinchSize(11, 100, 80)).toBe(8.8);
	});

	it('clamps', () => {
		expect(pinchSize(11, 100, 400)).toBe(24);
		expect(pinchSize(11, 100, 10)).toBe(6);
	});

	it('survives fingers that start on the same point', () => {
		expect(pinchSize(11, 0, 50)).toBe(11);
	});
});

describe('anchorScroll', () => {
	it('keeps the point under the fingers in place, on either axis', () => {
		// Horizontal: text 300px in is under a finger 100px from the edge.
		expect(anchorScroll({ scroll: 200, mid: 100, ratio: 2 })).toBe(500);
		// Vertical: the same rule with other numbers.
		expect(anchorScroll({ scroll: 1000, mid: 400, ratio: 0.5 })).toBe(300);
		// Check: the content point (scroll + mid) scaled lands back at mid.
		const scroll = anchorScroll({ scroll: 730, mid: 215, ratio: 1.6 });
		expect(scroll + 215).toBeCloseTo((730 + 215) * 1.6);
	});

	it('does not scale the padding before the text', () => {
		// 12px of padding, finger at 112px: the text point is 100px into the text.
		const scroll = anchorScroll({ scroll: 0, mid: 112, ratio: 2, offset: 12 });
		expect(scroll + 112).toBe(12 + 100 * 2);
	});

	it('follows a midpoint that moves during the pinch', () => {
		expect(anchorScroll({ scroll: 200, mid: 100, ratio: 2, midNow: 130 })).toBe(470);
	});

	it('changes nothing at ratio 1', () => {
		expect(anchorScroll({ scroll: 340, mid: 90, ratio: 1, offset: 12 })).toBe(340);
	});
});

describe('chatSize', () => {
	it('is 15px at the default and follows by ratio', () => {
		expect(chatSize(11)).toBe(15);
		expect(chatSize(22)).toBe(30);
	});
});

describe('boxSize', () => {
	it('is 16px at the default size and under it', () => {
		expect(boxSize(DEFAULT_SIZE)).toBe(BOX_MIN);
		expect(boxSize(MIN_SIZE)).toBe(BOX_MIN);
	});

	it('follows the chat text once that is larger', () => {
		expect(boxSize(16.5)).toBe(22.5);
		expect(boxSize(MAX_SIZE)).toBe(Math.round(chatSize(MAX_SIZE) * 10) / 10);
		expect(boxSize(MAX_SIZE)).toBeGreaterThan(30);
	});
});
