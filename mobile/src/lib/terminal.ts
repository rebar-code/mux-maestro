import { parseAnsi, spanColors, type Span } from './ansi';

/** A span as the view draws it. */
export interface ViewSpan {
	text: string;
	color?: string;
	background?: string;
	bold: boolean;
	dim: boolean;
	italic: boolean;
	underline: boolean;
}

export interface ViewLine {
	/** A number that stays with this line when lines are added above or below. */
	n: number;
	spans: ViewSpan[];
}

/** A run of lines the browser can skip drawing while it is off screen. */
export interface Block {
	key: number;
	lines: ViewLine[];
}

export const BLOCK_SIZE = 100;

/** The text as lines, without the empty one a final newline leaves. */
export function rawLines(text: string): string[] {
	const lines = text.split('\n');
	if (lines.length && lines[lines.length - 1] === '') lines.pop();
	return lines;
}

const blank = (line: Span[]): boolean =>
	line.every((span) => span.bg === undefined && !span.inverse && span.text.trim() === '');

/** Parse terminal text for drawing. Empty lines below the last line with text are left out. */
export function viewLines(text: string, base: number): { lines: ViewLine[]; cols: number } {
	const parsed = parseAnsi(text);
	while (parsed.length && blank(parsed[parsed.length - 1])) parsed.pop();
	let cols = 0;
	const lines = parsed.map((spans, index) => {
		let width = 0;
		const view = spans.map((span): ViewSpan => {
			width += span.text.length;
			return {
				text: span.text,
				...spanColors(span),
				bold: span.bold === true,
				dim: span.dim === true,
				italic: span.italic === true,
				underline: span.underline === true
			};
		});
		cols = Math.max(cols, width);
		return { n: base + index, spans: view };
	});
	return { lines, cols };
}

/** Group lines by their number, so a block keeps its lines as the text moves. */
export function toBlocks(lines: ViewLine[], size = BLOCK_SIZE): Block[] {
	const blocks: Block[] = [];
	for (const line of lines) {
		const key = Math.floor(line.n / size);
		const last = blocks[blocks.length - 1];
		if (last && last.key === key) last.lines.push(line);
		else blocks.push({ key, lines: [line] });
	}
	return blocks;
}

/** Whether the pane may hold lines above the ones we have. */
export function hasOlder(count: number, lines: number, max: number): boolean {
	return lines < max && count >= lines;
}

const COMPARE = 20;

function matches(a: string[], aStart: number, b: string[], bStart: number): boolean {
	const count = Math.min(COMPARE, a.length - aStart, b.length - bStart);
	if (count <= 0) return false;
	for (let i = 0; i < count; i += 1) if (a[aStart + i] !== b[bStart + i]) return false;
	return true;
}

/**
 * How far the old lines moved in the new text: old line `i` is new line
 * `i + shift`. Negative when lines fell off the top (new output with a full
 * window), positive when older lines were added above. Null when the two do
 * not line up (the screen was cleared, say).
 */
export function alignShift(before: string[], after: string[]): number | null {
	if (!before.length || !after.length) return null;
	// New output pushed `k` lines off the top: the new text starts at old line `k`.
	for (let k = 0; k < before.length; k += 1)
		if (matches(before, k, after, 0)) return k === 0 ? 0 : -k;
	// Older lines were added above: the old text starts at new line `p`.
	for (let p = 1; p < after.length; p += 1) if (matches(before, 0, after, p)) return p;
	return null;
}
