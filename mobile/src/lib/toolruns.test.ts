import { describe, expect, it } from 'vitest';
import { chatRows, foldLabel, type ChatRow } from './toolruns';
import type { ChatMessage } from './types';

/** `u`: user, `a`: assistant, `r`: reasoning, `t`: tool. Row `n` is its place. */
const chat = (roles: string): ChatMessage[] =>
	[...roles].map((role, n) => ({
		n,
		role: ({ u: 'user', a: 'assistant', r: 'reasoning', t: 'tool' } as const)[
			role as 'u' | 'a' | 'r' | 't'
		],
		text: `${role}${n}`
	}));

/** A message as its `n`; a fold as `[its hidden rows]`, `+` when open. */
const drawn = (rows: ChatRow[]): string =>
	rows
		.map((row) =>
			row.kind === 'message'
				? String(row.message.n)
				: `[${row.hidden.map((message) => message.n).join(',')}]${row.open ? '+' : ''}`
		)
		.join(' ');

const none = new Set<number>();

describe('the rows of a chat', () => {
	it('leaves a run of three tool calls or fewer as it is', () => {
		expect(drawn(chatRows(chat('uattta'), none))).toBe('0 1 2 3 4 5');
		expect(drawn(chatRows(chat('t'), none))).toBe('0');
		expect(drawn(chatRows([], none))).toBe('');
	});

	it('cuts a longer run to its last three, behind a fold', () => {
		expect(drawn(chatRows(chat('utttttta'), none))).toBe('0 [1,2,3] 4 5 6 7');
	});

	it('shows the whole run under the fold when it is open', () => {
		expect(drawn(chatRows(chat('utttttta'), new Set([1])))).toBe('0 [1,2,3]+ 1 2 3 4 5 6 7');
	});

	it('ends a run at anything the agent says or thinks', () => {
		expect(drawn(chatRows(chat('ttattrtttt'), none))).toBe('0 1 2 3 4 5 [6] 7 8 9');
	});

	it('folds each run by itself', () => {
		const rows = chatRows(chat('ttttattttt'), new Set([5]));
		expect(drawn(rows)).toBe('[0] 1 2 3 4 [5,6]+ 5 6 7 8 9');
	});

	it('keeps a fold open while its run grows', () => {
		const open = new Set([1]);
		expect(drawn(chatRows(chat('utttt'), open))).toBe('0 [1]+ 1 2 3 4');
		expect(drawn(chatRows(chat('utttttt'), open))).toBe('0 [1,2,3]+ 1 2 3 4 5 6');
	});
});

describe('the label of a fold', () => {
	it('counts the hidden rows, and offers the short run back when open', () => {
		expect(foldLabel(1, false)).toBe('1 more tool call');
		expect(foldLabel(7, false)).toBe('7 more tool calls');
		expect(foldLabel(7, true)).toBe('Show last 3');
	});
});
