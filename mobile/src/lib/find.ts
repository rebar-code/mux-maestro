import type { ChatMessage, FindMatch, Range } from './types';

/** The most places in a chat that are marked. */
export const MAX_CHAT_HITS = 500;

/**
 * Every place `query` is in `text`. The query is plain text. It ignores case
 * until it holds an uppercase letter, the rule the Mac's search uses.
 */
export function occurrences(text: string, query: string): Range[] {
	const needle = query.trim();
	if (!needle) return [];
	const exact = needle !== needle.toLowerCase();
	const hay = exact ? text : text.toLowerCase();
	const find = exact ? needle : needle.toLowerCase();
	// Lowercasing can change a string's length; then offsets would not line up.
	if (hay.length !== text.length) return [];
	const out: Range[] = [];
	let from = 0;
	for (;;) {
		const at = hay.indexOf(find, from);
		if (at < 0) return out;
		out.push([at, at + find.length]);
		from = at + find.length;
	}
}

/** One place the query is: `index` counts through the whole view. */
export interface Hit {
	index: number;
	range: Range;
}

/**
 * The hits of each chat row, keyed by the row's `n`, and how many there are.
 * `textOf` is the text a row shows, when that is not the text it holds.
 */
export function chatHits(
	messages: ChatMessage[],
	query: string,
	textOf: (message: ChatMessage) => string = (message) => message.text
): { byRow: Map<number, Hit[]>; count: number } {
	const byRow = new Map<number, Hit[]>();
	let count = 0;
	for (const message of messages) {
		if (count >= MAX_CHAT_HITS) break;
		const hits = occurrences(textOf(message), query)
			.slice(0, MAX_CHAT_HITS - count)
			.map((range, i) => ({ index: count + i, range }));
		if (!hits.length) continue;
		byRow.set(message.n, hits);
		count += hits.length;
	}
	return { byRow, count };
}

/** The Mac's matches (a line and offsets in it) as hits in the whole text. */
export function terminalHits(text: string, matches: FindMatch[]): Hit[] {
	const starts: number[] = [0];
	for (let at = text.indexOf('\n'); at >= 0; at = text.indexOf('\n', at + 1)) starts.push(at + 1);
	const out: Hit[] = [];
	for (const match of matches) {
		const base = starts[match.line];
		if (base === undefined) continue;
		for (const [start, end] of match.ranges) {
			out.push({ index: out.length, range: [base + start, base + end] });
		}
	}
	return out;
}

/** A run of text: a hit (with its index) or the text between two hits. */
export interface Segment {
	text: string;
	hit: number | null;
}

/** `text` cut at its hits, in order. Hits must not overlap. */
export function segments(text: string, hits: Hit[]): Segment[] {
	const out: Segment[] = [];
	let at = 0;
	for (const { index, range } of hits) {
		const [start, end] = range;
		if (start < at || end > text.length || end <= start) continue;
		if (start > at) out.push({ text: text.slice(at, start), hit: null });
		out.push({ text: text.slice(start, end), hit: index });
		at = end;
	}
	if (at < text.length || out.length === 0) out.push({ text: text.slice(at), hit: null });
	return out;
}

/** The next or the previous hit, going round at the ends. */
export function step(index: number, count: number, delta: 1 | -1): number {
	if (count <= 0) return 0;
	return (index + delta + count) % count;
}

/** "2/7", "0/0", or "3/200+" when the Mac left matches out. */
export function countLabel(index: number, count: number, truncated: boolean): string {
	return `${count ? index + 1 : 0}/${count}${truncated ? '+' : ''}`;
}
