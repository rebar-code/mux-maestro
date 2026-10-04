/**
 * A program in the pane can ask its terminal a question: what are you, where
 * is the cursor, what colour is the background. tmux is that terminal and
 * answers. xterm.js would answer as well, and its answer would travel to the
 * pane as if it had been typed. So the phone's terminal is made deaf to every
 * question: what the pane prints can then never cause a key press.
 */
interface FunctionId {
	prefix?: string;
	intermediates?: string;
	final: string;
}

/** The part of xterm.js's parser this needs. */
export interface QueryParser {
	registerCsiHandler(id: FunctionId, callback: (params: (number | number[])[]) => boolean): unknown;
	registerDcsHandler(id: FunctionId, callback: (data: string) => boolean): unknown;
	registerOscHandler(ident: number, callback: (data: string) => boolean): unknown;
}

/** Sequences that only ever ask for a report. Each is taken and dropped. */
const CSI_QUERIES: FunctionId[] = [
	// Device attributes: primary, secondary, tertiary.
	{ final: 'c' },
	{ prefix: '>', final: 'c' },
	{ prefix: '=', final: 'c' },
	// Device status and cursor position, plain and DEC.
	{ final: 'n' },
	{ prefix: '?', final: 'n' },
	// Mode requests (DECRQM), ANSI and DEC.
	{ intermediates: '$', final: 'p' },
	{ prefix: '?', intermediates: '$', final: 'p' },
	// Terminal version, window reports, keyboard protocol query.
	{ prefix: '>', final: 'q' },
	{ final: 't' },
	{ prefix: '?', final: 'u' }
];

/** Settings and capability requests (DECRQSS, XTGETTCAP). */
const DCS_QUERIES: FunctionId[] = [
	{ intermediates: '$', final: 'q' },
	{ intermediates: '+', final: 'q' }
];

/** Colour commands: palette, foreground, background, cursor. A `?` asks. */
const OSC_COLOURS = [4, 10, 11, 12, 13, 14, 15, 16, 17, 19];

export function silenceQueries(parser: QueryParser): void {
	for (const id of CSI_QUERIES) parser.registerCsiHandler(id, () => true);
	for (const id of DCS_QUERIES) parser.registerDcsHandler(id, () => true);
	// Setting a colour still works; only the question is dropped.
	for (const ident of OSC_COLOURS) parser.registerOscHandler(ident, (data) => data.includes('?'));
}

/** Focus reports, which a pane can switch on: taking focus is not typing. */
export function isReport(data: string): boolean {
	return data === '\x1b[I' || data === '\x1b[O';
}
