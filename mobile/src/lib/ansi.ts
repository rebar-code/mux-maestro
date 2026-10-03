/**
 * Turns terminal output with ANSI escape sequences into styled spans.
 *
 * Only colour and text attributes (SGR) are kept. Every other escape sequence
 * is dropped. Colours leave here as `rgb(r, g, b)` strings built from checked
 * numbers, so no text from the terminal ever becomes part of a style.
 */

export interface Span {
	text: string;
	fg?: string;
	bg?: string;
	bold?: true;
	dim?: true;
	italic?: true;
	underline?: true;
	inverse?: true;
}

type Rgb = readonly [number, number, number];

/** The 16 base colours, chosen to read well on the app's near-black background. */
const BASE: readonly Rgb[] = [
	[72, 72, 72],
	[248, 81, 73],
	[69, 212, 131],
	[227, 179, 65],
	[50, 145, 255],
	[163, 113, 247],
	[57, 197, 207],
	[207, 207, 207],
	[110, 110, 110],
	[255, 123, 114],
	[110, 231, 160],
	[248, 210, 106],
	[108, 182, 255],
	[196, 165, 255],
	[118, 227, 234],
	[255, 255, 255]
];
const CUBE = [0, 95, 135, 175, 215, 255] as const;

export const DEFAULT_FG = 'rgb(207, 207, 207)';
export const DEFAULT_BG = 'rgb(10, 10, 10)';

const byte = (n: number): boolean => Number.isInteger(n) && n >= 0 && n <= 255;
const css = ([r, g, b]: Rgb): string => `rgb(${r}, ${g}, ${b})`;

/** A colour from the 256-colour table, or undefined for a number outside it. */
export function indexed(n: number): string | undefined {
	if (!byte(n)) return undefined;
	if (n < 16) return css(BASE[n]);
	if (n < 232) {
		const c = n - 16;
		return css([CUBE[Math.floor(c / 36)], CUBE[Math.floor(c / 6) % 6], CUBE[c % 6]]);
	}
	const grey = 8 + (n - 232) * 10;
	return css([grey, grey, grey]);
}

export function truecolor(r: number, g: number, b: number): string | undefined {
	return byte(r) && byte(g) && byte(b) ? css([r, g, b]) : undefined;
}

type Style = Omit<Span, 'text'>;

/** A parameter as a number. Empty is 0; anything that is not a short number is NaN. */
function num(text: string | undefined): number {
	if (text === undefined || text === '') return 0;
	return /^\d{1,4}$/.test(text) ? Number(text) : Number.NaN;
}

function setFlag(
	style: Style,
	key: 'bold' | 'dim' | 'italic' | 'underline' | 'inverse',
	on: boolean
): void {
	if (on) style[key] = true;
	else delete style[key];
}

function setColor(style: Style, key: 'fg' | 'bg', value: string | undefined): void {
	if (value === undefined) delete style[key];
	else style[key] = value;
}

/** Apply one SGR sequence's parameters (the text between `ESC[` and `m`). */
function applySgr(style: Style, params: string): void {
	const parts = params.split(';');
	for (let i = 0; i < parts.length; i += 1) {
		const sub = parts[i].split(':');
		const code = num(sub[0]);
		if (code === 38 || code === 48 || code === 58) {
			// An extended colour: `38;5;n`, `38;2;r;g;b`, or the same with colons.
			let color: string | undefined;
			if (sub.length > 1) {
				if (sub[1] === '5') color = indexed(num(sub[2]));
				else if (sub[1] === '2') {
					const [r, g, b] = sub.slice(sub.length >= 6 ? 3 : 2).map(num);
					color = truecolor(r, g, b);
				}
			} else {
				const kind = num(parts[i + 1]);
				if (kind === 5) {
					color = parts.length > i + 2 ? indexed(num(parts[i + 2])) : undefined;
					i += 2;
				} else if (kind === 2) {
					color =
						parts.length > i + 4
							? truecolor(num(parts[i + 2]), num(parts[i + 3]), num(parts[i + 4]))
							: undefined;
					i += 4;
				} else {
					// Not a form we know: the rest of this sequence cannot be trusted.
					return;
				}
			}
			// A colour that is malformed changes nothing. 58 (underline colour) is not drawn.
			if (color !== undefined && code !== 58) setColor(style, code === 38 ? 'fg' : 'bg', color);
			continue;
		}
		if (code === 0) {
			for (const key of Object.keys(style) as (keyof Style)[]) delete style[key];
		} else if (code === 1) setFlag(style, 'bold', true);
		else if (code === 2) setFlag(style, 'dim', true);
		else if (code === 3) setFlag(style, 'italic', true);
		else if (code === 4 || code === 21) setFlag(style, 'underline', sub[1] !== '0');
		else if (code === 7) setFlag(style, 'inverse', true);
		else if (code === 22) {
			setFlag(style, 'bold', false);
			setFlag(style, 'dim', false);
		} else if (code === 23) setFlag(style, 'italic', false);
		else if (code === 24) setFlag(style, 'underline', false);
		else if (code === 27) setFlag(style, 'inverse', false);
		else if (code >= 30 && code <= 37) setColor(style, 'fg', indexed(code - 30));
		else if (code === 39) setColor(style, 'fg', undefined);
		else if (code >= 40 && code <= 47) setColor(style, 'bg', indexed(code - 40));
		else if (code === 49) setColor(style, 'bg', undefined);
		else if (code >= 90 && code <= 97) setColor(style, 'fg', indexed(code - 90 + 8));
		else if (code >= 100 && code <= 107) setColor(style, 'bg', indexed(code - 100 + 8));
	}
}

const sameStyle = (a: Style, b: Style): boolean =>
	a.fg === b.fg &&
	a.bg === b.bg &&
	a.bold === b.bold &&
	a.dim === b.dim &&
	a.italic === b.italic &&
	a.underline === b.underline &&
	a.inverse === b.inverse;

const ESC = 0x1b;
const BEL = 0x07;

/**
 * Parse `text` into lines of spans. A line with no text is an empty list. The
 * style carries over from one line to the next, as it does on a terminal.
 */
export function parseAnsi(text: string): Span[][] {
	const lines: Span[][] = [];
	const style: Style = {};
	let line: Span[] = [];
	let run = '';

	const flush = (): void => {
		if (!run) return;
		const last = line[line.length - 1];
		if (last && sameStyle(last, style)) last.text += run;
		else line.push({ text: run, ...style });
		run = '';
	};

	const length = text.length;
	let i = 0;
	while (i < length) {
		const code = text.charCodeAt(i);
		if (code === 0x0a) {
			flush();
			lines.push(line);
			line = [];
			i += 1;
		} else if (code === ESC) {
			const next = text.charCodeAt(i + 1);
			if (next === 0x5b) {
				// CSI: parameters, intermediates, one final byte.
				let j = i + 2;
				while (j < length && text.charCodeAt(j) >= 0x30 && text.charCodeAt(j) <= 0x3f) j += 1;
				const params = text.slice(i + 2, j);
				const intermediate = j;
				while (j < length && text.charCodeAt(j) >= 0x20 && text.charCodeAt(j) <= 0x2f) j += 1;
				const final = text.charCodeAt(j);
				if (j >= length) {
					// Cut off before its end: nothing of it is shown.
					i = length;
				} else if (final >= 0x40 && final <= 0x7e) {
					if (final === 0x6d && j === intermediate && !/^[<=>?]/.test(params)) {
						flush();
						applySgr(style, params);
					}
					i = j + 1;
				} else {
					// Not a valid sequence: drop the introducer, keep reading from here.
					i = j;
				}
			} else if (
				next === 0x5d ||
				next === 0x50 ||
				next === 0x5f ||
				next === 0x5e ||
				next === 0x58
			) {
				// OSC, DCS, APC, PM, SOS: a string that runs to BEL or ST (ESC \).
				// It never runs past the end of its line, so a broken one hides one line at most.
				let j = i + 2;
				while (j < length) {
					const c = text.charCodeAt(j);
					if (c === BEL) {
						j += 1;
						break;
					}
					if (c === ESC && text.charCodeAt(j + 1) === 0x5c) {
						j += 2;
						break;
					}
					if (c === 0x0a) break;
					j += 1;
				}
				i = j;
			} else if (next >= 0x20 && next <= 0x2f) {
				// ESC, intermediates, final (for example a character-set choice).
				let j = i + 1;
				while (j < length && text.charCodeAt(j) >= 0x20 && text.charCodeAt(j) <= 0x2f) j += 1;
				i = Math.min(j + 1, length);
			} else if (Number.isNaN(next) || next === 0x0a) {
				i += 1;
			} else {
				// A two-character sequence.
				i += 2;
			}
		} else if (
			code === 0x09 ||
			(code >= 0x20 && code !== 0x7f && !(code >= 0x80 && code <= 0x9f))
		) {
			run += text[i];
			i += 1;
		} else {
			// Any other control character.
			i += 1;
		}
	}
	flush();
	lines.push(line);
	return lines;
}

/** The colours to draw a span with. Inverse swaps them, using the defaults where none is set. */
export function spanColors(span: Span): { color?: string; background?: string } {
	if (span.inverse) return { color: span.bg ?? DEFAULT_BG, background: span.fg ?? DEFAULT_FG };
	return { color: span.fg, background: span.bg };
}
