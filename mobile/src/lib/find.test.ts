import { describe, expect, it } from 'vitest';
import { chatHits, countLabel, occurrences, segments, step, terminalHits } from './find';
import type { ChatMessage } from './types';

describe('occurrences', () => {
	it('finds plain text and ignores case until the query has an uppercase letter', () => {
		expect(occurrences('Tax line, tax row', 'tax')).toEqual([
			[0, 3],
			[10, 13]
		]);
		expect(occurrences('Tax line, tax row', 'Tax')).toEqual([[0, 3]]);
		expect(occurrences('abc a.c', 'a.c')).toEqual([[4, 7]]);
		expect(occurrences('aaaa', 'aa')).toEqual([
			[0, 2],
			[2, 4]
		]);
	});

	it('finds nothing for an empty query', () => {
		expect(occurrences('tax', '')).toEqual([]);
		expect(occurrences('tax', '   ')).toEqual([]);
	});
});

const row = (n: number, text: string): ChatMessage => ({ n, role: 'assistant', text });

describe('chatHits', () => {
	it('numbers the hits through the rows', () => {
		const { byRow, count } = chatHits(
			[row(0, 'tax and tax'), row(5, 'nothing'), row(9, 'the tax row')],
			'tax'
		);
		expect(count).toBe(3);
		expect(byRow.get(0)?.map((hit) => hit.index)).toEqual([0, 1]);
		expect(byRow.has(5)).toBe(false);
		expect(byRow.get(9)).toEqual([{ index: 2, range: [4, 7] }]);
	});
});

describe('terminalHits', () => {
	it('turns a line and its offsets into offsets in the whole text', () => {
		const text = '$ make\ntax ok\n\nlast tax';
		const hits = terminalHits(text, [
			{ line: 1, ranges: [[0, 3]] },
			{ line: 3, ranges: [[5, 8]] },
			{ line: 9, ranges: [[0, 1]] }
		]);
		expect(hits.map((hit) => text.slice(...hit.range))).toEqual(['tax', 'tax']);
		expect(hits.map((hit) => hit.index)).toEqual([0, 1]);
	});
});

describe('segments', () => {
	it('cuts the text at its hits', () => {
		expect(
			segments('a tax b', [{ index: 4, range: [2, 5] }]).map((part) => [part.text, part.hit])
		).toEqual([
			['a ', null],
			['tax', 4],
			[' b', null]
		]);
		expect(segments('plain', [])).toEqual([{ text: 'plain', hit: null }]);
		expect(segments('tax', [{ index: 0, range: [0, 3] }])).toEqual([{ text: 'tax', hit: 0 }]);
	});

	it('leaves out a hit that is past the text', () => {
		expect(segments('ab', [{ index: 0, range: [1, 9] }])).toEqual([{ text: 'ab', hit: null }]);
	});
});

describe('step and countLabel', () => {
	it('goes round at the ends', () => {
		expect(step(0, 3, 1)).toBe(1);
		expect(step(2, 3, 1)).toBe(0);
		expect(step(0, 3, -1)).toBe(2);
		expect(step(0, 0, 1)).toBe(0);
	});

	it('labels the count', () => {
		expect(countLabel(1, 7, false)).toBe('2/7');
		expect(countLabel(0, 0, false)).toBe('0/0');
		expect(countLabel(2, 200, true)).toBe('3/200+');
	});
});
