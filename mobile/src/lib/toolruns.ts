import type { ChatMessage } from './types';

/** How many tool rows at the end of a run stay in view. */
export const TOOLS_SHOWN = 3;

/** One thing the chat draws: a message, or the control that stands for a run's earlier tool rows. */
export type ChatRow =
	| { kind: 'message'; message: ChatMessage }
	| {
			kind: 'fold';
			/** The `n` of the run's first tool row: the same as the run grows. */
			key: number;
			/** The rows the control stands for. */
			hidden: ChatMessage[];
			open: boolean;
	  };

/**
 * The chat's rows, with each run of tool calls cut to its last `TOOLS_SHOWN`.
 * A run is tool rows with nothing else between them. A longer run starts with
 * a fold; the rows it stands for follow it only when its key is in `open`.
 */
export function chatRows(messages: ChatMessage[], open: ReadonlySet<number>): ChatRow[] {
	const out: ChatRow[] = [];
	let at = 0;
	while (at < messages.length) {
		let end = at;
		while (end < messages.length && messages[end].role === 'tool') end += 1;
		if (end === at) {
			out.push({ kind: 'message', message: messages[at] });
			at += 1;
			continue;
		}
		const run = messages.slice(at, end);
		const hidden = run.slice(0, Math.max(run.length - TOOLS_SHOWN, 0));
		if (hidden.length) {
			const key = run[0].n;
			out.push({ kind: 'fold', key, hidden, open: open.has(key) });
		}
		const shown = hidden.length && !open.has(run[0].n) ? run.slice(hidden.length) : run;
		for (const message of shown) out.push({ kind: 'message', message });
		at = end;
	}
	return out;
}

/** What the fold's button says. */
export function foldLabel(hidden: number, open: boolean): string {
	if (open) return `Show last ${TOOLS_SHOWN}`;
	return hidden === 1 ? '1 more tool call' : `${hidden} more tool calls`;
}
