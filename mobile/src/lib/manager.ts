import type { ChatMessage, ManagerItem, ManagerTurn, Thread } from './types';

/** One line under the talk button. */
export interface HomeLine {
	role: 'user' | 'manager';
	text: string;
	/** The reply is still being written. */
	live?: boolean;
}

/** How many lines of the conversation the home shows. */
export const HOME_LINES = 3;

/**
 * The manager's last lines: the end of the chat, then the turn in flight. The
 * transcript gets a turn's prompt before the turn ends, so a chat that already
 * ends in that prompt is cut there and the turn is not shown twice.
 */
export function homeLines(chat: ChatMessage[], turn: ManagerTurn | null): HomeLine[] {
	let lines: HomeLine[] = chat
		.filter((message) => message.role !== 'tool')
		.map((message) => ({
			role: message.role === 'user' ? 'user' : 'manager',
			text: message.text
		}));
	if (turn) {
		const last = lines.findLastIndex((line) => line.role === 'user');
		if (last >= 0 && lines[last].text === turn.prompt) lines = lines.slice(0, last);
		lines.push(
			{ role: 'user', text: turn.prompt },
			{ role: 'manager', text: turn.reply, live: true }
		);
	}
	return lines.slice(-HOME_LINES);
}

export interface NeedsYouCard {
	thread: Thread;
	/** Why it waits, when the manager knows. */
	why: string | null;
}

/** The threads that wait for the human, each with the manager's reason. */
export function needsYouCards(threads: Thread[], items: ManagerItem[]): NeedsYouCard[] {
	return threads
		.filter((thread) => thread.status === 'waiting')
		.map((thread) => ({
			thread,
			why: items.find((item) => item.thread === thread.id)?.detail || null
		}));
}
