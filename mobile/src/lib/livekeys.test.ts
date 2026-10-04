import { describe, expect, it } from 'vitest';
import { barKeyText, BATCH, BATCH_MS, ctrlChar, messages, Pacer, typed } from './livekeys';
import { BAR_KEYS } from './reply';

const key = (label: string) => BAR_KEYS.find((k) => k.label === label)!;

describe('barKeyText', () => {
	it('gives every key of the bar its bytes', () => {
		expect(barKeyText(key('Esc'), false)).toBe('\x1b');
		expect(barKeyText(key('Tab'), false)).toBe('\t');
		expect(barKeyText(key('Sh+Tab'), false)).toBe('\x1b[Z');
		expect(barKeyText(key('Ctrl+C'), false)).toBe('\x03');
		expect(barKeyText(key('⏎'), false)).toBe('\r');
		expect(barKeyText(key('/'), false)).toBe('/');
		expect(barKeyText(key('|'), false)).toBe('|');
	});

	it('sends arrows in the form the pane asked for', () => {
		expect(barKeyText(key('↑'), false)).toBe('\x1b[A');
		expect(barKeyText(key('↓'), false)).toBe('\x1b[B');
		expect(barKeyText(key('→'), true)).toBe('\x1bOC');
		expect(barKeyText(key('←'), true)).toBe('\x1bOD');
	});

	it('has nothing for Ctrl itself or a key it does not know', () => {
		expect(barKeyText(key('Ctrl'), false)).toBeNull();
		expect(barKeyText({ label: 'x', aria: 'x', send: 'F13' }, false)).toBeNull();
	});
});

describe('sticky Ctrl', () => {
	it('turns one character into its control character', () => {
		expect(ctrlChar('c')).toBe('\x03');
		expect(ctrlChar('C')).toBe('\x03');
		expect(ctrlChar('[')).toBe('\x1b');
		expect(ctrlChar('?')).toBe('\x7f');
		expect(ctrlChar('1')).toBeNull();
		expect(ctrlChar('ab')).toBeNull();
	});

	it('leaves what has no control character as it is', () => {
		expect(typed('d', true)).toBe('\x04');
		expect(typed('d', false)).toBe('d');
		expect(typed('é', true)).toBe('é');
		expect(typed('\x1b[A', true)).toBe('\x1b[A');
	});
});

describe('messages', () => {
	it('cuts long text into bounded messages and loses no byte', () => {
		const text = 'é'.repeat(3000);
		const parts = messages(text, 2048);
		expect(parts.map((p) => p.length)).toEqual([2048, 2048, 1904]);
		const joined = new Uint8Array(6000);
		let at = 0;
		for (const part of parts) {
			joined.set(part, at);
			at += part.length;
		}
		expect(new TextDecoder().decode(joined)).toBe(text);
	});

	it('sends nothing for nothing', () => {
		expect(messages('')).toEqual([]);
	});
});

describe('Pacer', () => {
	it('sends what is typed at once', () => {
		const sent: number[] = [];
		const pacer = new Pacer<number>((n) => sent.push(n));
		pacer.push([1]);
		pacer.push([2, 3]);
		expect(sent).toEqual([1, 2, 3]);
	});

	it('sends a long paste a lot at a time, in order', () => {
		const sent: number[] = [];
		const waits: number[] = [];
		let next: (() => void) | null = null;
		const pacer = new Pacer<number>(
			(n) => sent.push(n),
			(run, ms) => {
				next = run;
				waits.push(ms);
				return 0 as unknown as ReturnType<typeof setTimeout>;
			}
		);
		const all = Array.from({ length: BATCH * 2 + 5 }, (_, n) => n);
		pacer.push(all);
		expect(sent).toHaveLength(BATCH);
		// Typed while the paste goes out: it waits its turn.
		pacer.push([999]);
		expect(sent).toHaveLength(BATCH);
		next!();
		expect(sent).toHaveLength(BATCH * 2);
		next!();
		expect(sent).toEqual([...all, 999]);
		expect(waits).toEqual([BATCH_MS, BATCH_MS]);
	});

	it('forgets the rest when the socket has gone', () => {
		const sent: number[] = [];
		const pacer = new Pacer<number>(
			(n) => sent.push(n),
			() => setTimeout(() => {}, 0)
		);
		pacer.push(Array.from({ length: BATCH + 10 }, (_, n) => n));
		pacer.clear();
		pacer.push([7]);
		expect(sent).toHaveLength(BATCH + 1);
		expect(sent.at(-1)).toBe(7);
	});
});
