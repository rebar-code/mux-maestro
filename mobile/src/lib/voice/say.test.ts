import { describe, expect, it } from 'vitest';
import { sameMessage, sayState, sayTap, type SayKey } from './say';

const a: SayKey = { target: 'localhost:7', n: 40 };
const b: SayKey = { target: 'localhost:7', n: 52 };

describe('the play button: one message at a time', () => {
	it('starts the tapped message when nothing is read', () => {
		expect(sayTap(null, a)).toEqual({ stop: false, start: a });
	});

	it('stops the message that is read before another starts', () => {
		expect(sayTap(a, b)).toEqual({ stop: true, start: b });
	});

	it('stops, and starts nothing, on a tap of the message that is read', () => {
		expect(sayTap(a, { ...a })).toEqual({ stop: true, start: null });
	});

	it('tells the same row of two panes apart', () => {
		const other: SayKey = { target: 'manager', n: a.n };
		expect(sameMessage(a, other)).toBe(false);
		expect(sayTap(a, other)).toEqual({ stop: true, start: other });
	});
});

describe('what a play button shows', () => {
	it('shows Play on every message but the one that is read', () => {
		expect(sayState(null, a, false)).toBe('idle');
		expect(sayState(b, a, true)).toBe('idle');
		expect(sayState({ target: 'manager', n: a.n }, a, true)).toBe('idle');
	});

	it('shows progress until audio plays, then Stop', () => {
		expect(sayState(a, a, false)).toBe('loading');
		expect(sayState(a, a, true)).toBe('playing');
	});

	it('is back at Play once the message is finished', () => {
		expect(sayState(null, a, false)).toBe('idle');
	});
});
