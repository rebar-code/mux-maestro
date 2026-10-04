import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { paced } from './reply';

describe('paced', () => {
	beforeEach(() => vi.useFakeTimers());
	afterEach(() => vi.useRealTimers());

	it('hands on the first piece at once and the next ones together', () => {
		const got: string[] = [];
		const pace = paced(100, (text) => got.push(text));
		pace.add('a ');
		expect(got).toEqual(['a ']);
		pace.add('b ');
		pace.add('c ');
		expect(got).toEqual(['a ']);
		vi.advanceTimersByTime(99);
		expect(got).toEqual(['a ']);
		vi.advanceTimersByTime(1);
		expect(got).toEqual(['a ', 'b c ']);
		// After a quiet time the next piece is at once again.
		vi.advanceTimersByTime(100);
		pace.add('d');
		expect(got).toEqual(['a ', 'b c ', 'd']);
	});

	it('a reply of 523 pieces in two seconds is handed on about 20 times, with nothing lost', () => {
		const got: string[] = [];
		const pace = paced(100, (text) => got.push(text));
		const pieces = Array.from({ length: 523 }, (_, n) => `w${n} `);
		for (const piece of pieces) {
			pace.add(piece);
			vi.advanceTimersByTime(4);
		}
		pace.flush();
		expect(got.join('')).toBe(pieces.join(''));
		expect(got.length).toBeLessThanOrEqual(23);
	});

	it('flush hands on what is held; cancel drops it', () => {
		const got: string[] = [];
		const pace = paced(100, (text) => got.push(text));
		pace.add('a');
		pace.add('b');
		pace.flush();
		expect(got).toEqual(['a', 'b']);
		pace.add('c');
		pace.cancel();
		vi.advanceTimersByTime(500);
		pace.flush();
		expect(got).toEqual(['a', 'b']);
	});
});
