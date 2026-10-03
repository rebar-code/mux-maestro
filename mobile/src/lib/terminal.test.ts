import { describe, expect, it } from 'vitest';
import { alignShift, hasOlder, rawLines, toBlocks, viewLines } from './terminal';

const numbered = (from: number, to: number): string[] =>
	Array.from({ length: to - from + 1 }, (_, i) => `line ${from + i}`);

describe('rawLines', () => {
	it('drops only the empty line after a final newline', () => {
		expect(rawLines('a\nb\n')).toEqual(['a', 'b']);
		expect(rawLines('a\n\nb')).toEqual(['a', '', 'b']);
		expect(rawLines('')).toEqual([]);
	});
});

describe('viewLines', () => {
	it('numbers lines from the base and measures the widest', () => {
		const { lines, cols } = viewLines('ab\n\x1b[31mcdef\x1b[0m!', 40);
		expect(lines.map((line) => line.n)).toEqual([40, 41]);
		expect(cols).toBe(5);
		expect(lines[1].spans[0]).toMatchObject({
			text: 'cdef',
			color: 'rgb(248, 81, 73)',
			bold: false
		});
	});

	it('leaves out blank lines at the end, but not ones with a background', () => {
		expect(viewLines('a\n\n  \n\x1b[0m\n', 0).lines).toHaveLength(1);
		expect(viewLines('a\n\x1b[41m  \x1b[0m\n', 0).lines).toHaveLength(2);
	});
});

describe('toBlocks', () => {
	it('groups by line number, so blocks hold as the window moves', () => {
		const lines = viewLines(numbered(1, 250).join('\n'), 95).lines;
		const blocks = toBlocks(lines);
		expect(blocks.map((block) => [block.key, block.lines.length])).toEqual([
			[0, 5],
			[1, 100],
			[2, 100],
			[3, 45]
		]);
	});

	it('handles numbers below zero (lines loaded above the first)', () => {
		const blocks = toBlocks(viewLines('a\nb\nc', -2).lines);
		expect(blocks.map((block) => [block.key, block.lines.length])).toEqual([
			[-1, 2],
			[0, 1]
		]);
	});
});

describe('hasOlder', () => {
	it('is true while the text fills what was asked for and the cap is not reached', () => {
		expect(hasOlder(2000, 2000, 10000)).toBe(true);
		expect(hasOlder(500, 2000, 10000)).toBe(false);
		expect(hasOlder(10000, 10000, 10000)).toBe(false);
	});
});

describe('alignShift', () => {
	it('is 0 when lines were only added below', () => {
		expect(alignShift(numbered(1, 50), numbered(1, 60))).toBe(0);
	});

	it('is negative when new output pushed lines off the top', () => {
		expect(alignShift(numbered(1, 100), numbered(11, 110))).toBe(-10);
	});

	it('is positive when older lines were loaded above', () => {
		expect(alignShift(numbered(101, 200), numbered(1, 200))).toBe(100);
	});

	it('still lines up when the bottom of the screen was redrawn', () => {
		const before = [...numbered(1, 80), 'prompt >', 'status: idle'];
		const after = [...numbered(6, 80), 'more', 'prompt > x', 'status: busy'];
		expect(alignShift(before, after)).toBe(-5);
	});

	it('is null when nothing lines up', () => {
		expect(alignShift(numbered(1, 50), ['cleared', 'screen'])).toBeNull();
		expect(alignShift([], numbered(1, 5))).toBeNull();
	});
});
