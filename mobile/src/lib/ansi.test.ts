import { describe, expect, it } from 'vitest';
import { DEFAULT_BG, DEFAULT_FG, indexed, parseAnsi, spanColors, truecolor } from './ansi';

const E = '\x1b';
const one = (text: string) => parseAnsi(text)[0];
const shown = (text: string): string =>
	parseAnsi(text)
		.map((line) => line.map((span) => span.text).join(''))
		.join('\n');

describe('attributes', () => {
	it.each([
		['bold', 1, 22],
		['dim', 2, 22],
		['italic', 3, 23],
		['underline', 4, 24],
		['inverse', 7, 27]
	] as const)('%s on and off', (key, on, off) => {
		const line = one(`${E}[${on}mon${E}[${off}moff`);
		expect(line).toEqual([{ text: 'on', [key]: true }, { text: 'off' }]);
	});

	it('22 turns off bold and dim together', () => {
		expect(one(`${E}[1;2mx${E}[22my`)).toEqual([
			{ text: 'x', bold: true, dim: true },
			{ text: 'y' }
		]);
	});

	it('0 and an empty parameter both reset', () => {
		expect(one(`${E}[1;31;44mx${E}[0my`)[1]).toEqual({ text: 'y' });
		expect(one(`${E}[1;31;44mx${E}[my`)[1]).toEqual({ text: 'y' });
	});

	it('4:0 is underline off', () => {
		expect(one(`${E}[4mx${E}[4:0my`)).toEqual([{ text: 'x', underline: true }, { text: 'y' }]);
	});
});

describe('colours', () => {
	it('16 colours, foreground and background', () => {
		const [span] = one(`${E}[31;42mx`);
		expect(span).toEqual({ text: 'x', fg: indexed(1), bg: indexed(2) });
		expect(span.fg).toBe('rgb(248, 81, 73)');
	});

	it('bright colours', () => {
		expect(one(`${E}[91;104mx`)[0]).toEqual({ text: 'x', fg: indexed(9), bg: indexed(12) });
	});

	it('39 and 49 go back to the defaults', () => {
		expect(one(`${E}[31;42mx${E}[39my${E}[49mz`)).toEqual([
			{ text: 'x', fg: indexed(1), bg: indexed(2) },
			{ text: 'y', bg: indexed(2) },
			{ text: 'z' }
		]);
	});

	it('256 colours: cube and greys by formula', () => {
		expect(one(`${E}[38;5;208mx`)[0].fg).toBe('rgb(255, 135, 0)');
		expect(one(`${E}[48;5;17mx`)[0].bg).toBe('rgb(0, 0, 95)');
		expect(indexed(232)).toBe('rgb(8, 8, 8)');
		expect(indexed(255)).toBe('rgb(238, 238, 238)');
		expect(indexed(231)).toBe('rgb(255, 255, 255)');
	});

	it('truecolor, foreground and background', () => {
		expect(one(`${E}[38;2;255;100;0;48;2;1;2;3mx`)[0]).toEqual({
			text: 'x',
			fg: 'rgb(255, 100, 0)',
			bg: 'rgb(1, 2, 3)'
		});
	});

	it('the colon forms', () => {
		expect(one(`${E}[38:5:208mx`)[0].fg).toBe('rgb(255, 135, 0)');
		expect(one(`${E}[38:2:255:100:0mx`)[0].fg).toBe('rgb(255, 100, 0)');
		expect(one(`${E}[48:2::255:100:0mx`)[0].bg).toBe('rgb(255, 100, 0)');
	});

	it('a colour is followed by other parameters', () => {
		expect(one(`${E}[38;5;208;1mx`)[0]).toEqual({ text: 'x', fg: 'rgb(255, 135, 0)', bold: true });
	});

	it('inverse swaps the colours, with the defaults where none is set', () => {
		expect(spanColors({ text: 'x', inverse: true })).toEqual({
			color: DEFAULT_BG,
			background: DEFAULT_FG
		});
		expect(spanColors({ text: 'x', inverse: true, fg: indexed(1), bg: indexed(4) })).toEqual({
			color: indexed(4),
			background: indexed(1)
		});
		expect(spanColors({ text: 'x', fg: indexed(1) })).toEqual({
			color: indexed(1),
			background: undefined
		});
	});
});

describe('lines', () => {
	it('splits on newlines and keeps empty lines', () => {
		expect(parseAnsi('a\n\nb')).toEqual([[{ text: 'a' }], [], [{ text: 'b' }]]);
	});

	it('carries the style across lines until it is reset', () => {
		expect(parseAnsi(`${E}[32ma\nb${E}[0m\nc`)).toEqual([
			[{ text: 'a', fg: indexed(2) }],
			[{ text: 'b', fg: indexed(2) }],
			[{ text: 'c' }]
		]);
	});

	it('joins text of one style into one span', () => {
		expect(one(`a${E}[0mb${E}[39mc`)).toEqual([{ text: 'abc' }]);
	});

	it('keeps tabs and drops carriage returns', () => {
		expect(one('a\tb\r')).toEqual([{ text: 'a\tb' }]);
	});
});

describe('everything else is stripped', () => {
	it('markup is plain text in one span', () => {
		expect(one('<script>alert(1)</script>')).toEqual([{ text: '<script>alert(1)</script>' }]);
		expect(one('<img src=x onerror=alert(1)>&amp;')).toEqual([
			{ text: '<img src=x onerror=alert(1)>&amp;' }
		]);
	});

	it('an OSC title, ended by BEL or by ST', () => {
		expect(shown(`${E}]0;my title\x07after`)).toBe('after');
		expect(shown(`${E}]2;my title${E}\\after`)).toBe('after');
	});

	it('an OSC 8 hyperlink leaves its visible text', () => {
		const bel = `${E}]8;;https://example.com\x07link${E}]8;;\x07 tail`;
		const st = `${E}]8;id=1;https://example.com${E}\\link${E}]8;;${E}\\ tail`;
		expect(shown(bel)).toBe('link tail');
		expect(shown(st)).toBe('link tail');
	});

	it('cursor movement, erase and mode sequences', () => {
		expect(
			shown(`a${E}[2Jb${E}[10;20Hc${E}[Kd${E}[?25le${E}[?1049hf${E}[1Ag${E}[6nh${E}[2 qi`)
		).toBe('abcdefghi');
	});

	it('a private sequence that ends in m is not a colour', () => {
		expect(one(`${E}[>4;2mx`)).toEqual([{ text: 'x' }]);
	});

	it('DCS, APC, PM and SOS strings', () => {
		expect(shown(`a${E}Pq#0;2;0;0;0${E}\\b${E}_app${E}\\c${E}^pm${E}\\d${E}Xsos${E}\\e`)).toBe(
			'abcde'
		);
	});

	it('two-character and character-set sequences', () => {
		expect(shown(`a${E}7b${E}8c${E}=d${E}(Be${E}Mf`)).toBe('abcdef');
	});

	it('NUL and other control characters', () => {
		expect(shown('a\x00b\x07c\x08d\x0be\x0cf\x7fg\u009bh')).toBe('abcdefgh');
	});
});

describe('broken input', () => {
	it('a CSI cut off at the end shows nothing of itself', () => {
		expect(shown(`ok${E}[38;5`)).toBe('ok');
		expect(shown(`ok${E}[`)).toBe('ok');
		expect(shown(`ok${E}`)).toBe('ok');
	});

	it('an OSC cut off at the end shows nothing of itself', () => {
		expect(shown(`ok${E}]0;half a title`)).toBe('ok');
	});

	it('an unterminated string hides the rest of its line only', () => {
		expect(shown(`a${E}]0;no end\nnext line`)).toBe('a\nnext line');
		expect(shown(`a${E}Pno end\nnext line`)).toBe('a\nnext line');
	});

	it('an ESC before a newline does not eat the newline', () => {
		expect(shown(`a${E}\nb`)).toBe('a\nb');
	});

	it('an invalid byte inside a CSI drops only the introducer', () => {
		expect(shown(`a${E}[12\nb`)).toBe('a\nb');
	});

	it('38;5 with no number changes nothing', () => {
		expect(one(`${E}[38;5mx`)).toEqual([{ text: 'x' }]);
		expect(one(`${E}[31m${E}[38;5mx`)[0].fg).toBe(indexed(1));
	});

	it('truecolor out of range changes nothing, and its numbers are not read as codes', () => {
		expect(one(`${E}[38;2;300;0;0mx`)).toEqual([{ text: 'x' }]);
		expect(one(`${E}[38;2;1;1mx`)).toEqual([{ text: 'x' }]);
		expect(truecolor(300, 0, 0)).toBeUndefined();
		expect(truecolor(1.5, 0, 0)).toBeUndefined();
	});

	it('a 256-colour number out of range changes nothing', () => {
		expect(one(`${E}[38;5;256mx`)).toEqual([{ text: 'x' }]);
		expect(indexed(-1)).toBeUndefined();
	});

	it('empty parameters count as 0', () => {
		expect(one(`${E}[1m${E}[;mx`)).toEqual([{ text: 'x' }]);
		expect(one(`${E}[;1mx`)).toEqual([{ text: 'x', bold: true }]);
	});

	it('huge numbers are ignored', () => {
		expect(one(`${E}[99999999999999999999mx`)).toEqual([{ text: 'x' }]);
		expect(one(`${E}[38;5;99999999999mx`)).toEqual([{ text: 'x' }]);
		expect(one(`${E}[1;99999999999;3mx`)).toEqual([{ text: 'x', bold: true, italic: true }]);
	});

	it('an unknown extended-colour form stops that sequence', () => {
		expect(one(`${E}[38;9;1mx`)).toEqual([{ text: 'x' }]);
	});

	it('colours are only ever rgb() of three small numbers', () => {
		const hostile = `${E}[38;2;1);background:url(x);0;0mx${E}[38:2:1:2:red mx${E}[38;5;1e2my`;
		for (const line of parseAnsi(hostile)) {
			for (const span of line) {
				for (const value of [span.fg, span.bg]) {
					if (value !== undefined) expect(value).toMatch(/^rgb\(\d{1,3}, \d{1,3}, \d{1,3}\)$/);
				}
			}
		}
	});
});
