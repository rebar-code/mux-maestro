import type { ChatMessage, ManagerItem, Thread } from './types';

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

/**
 * The prompt of the turn in flight, while the chat does not hold it yet. The
 * transcript gets the prompt a moment after it is sent; until then it is drawn
 * from here, and never twice. `base` is the last row the chat held when the
 * turn began, so an older turn with the same words does not count.
 */
export function pendingPrompt(
	prompt: string | null,
	messages: ChatMessage[] | null,
	base: number
): string | null {
	if (prompt === null) return null;
	const landed = (messages ?? []).some(
		(message) => message.n > base && message.role === 'user' && message.text === prompt
	);
	return landed ? null : prompt;
}

/** "48s", "4m 48s", "1h 2m 3s". */
export function elapsedLabel(seconds: number): string {
	const s = Math.max(0, Math.floor(seconds));
	const parts = [
		s >= 3600 ? `${Math.floor(s / 3600)}h` : null,
		s >= 60 ? `${Math.floor((s % 3600) / 60)}m` : null,
		`${s % 60}s`
	];
	return parts.filter((part) => part !== null).join(' ');
}

/** Shown in turn while an agent works and its own spinner line cannot be read. */
export const THINKING_PHRASES = [
	'Thinking',
	'Reading the threads',
	'Checking the sessions',
	'Working it out',
	'Putting it together',
	'Still working'
];
/** How long each phrase stays. */
export const PHRASE_SECONDS = 4;

/**
 * The line beside the dots while an agent works: its own spinner line when the
 * Mac could read one, else a phrase that changes every few seconds with the
 * time so far.
 */
export function thinkingText(spinner: string | null, seconds: number): string {
	if (spinner) return spinner;
	const phrase =
		THINKING_PHRASES[Math.floor(Math.max(0, seconds) / PHRASE_SECONDS) % THINKING_PHRASES.length];
	return `${phrase}… ${elapsedLabel(seconds)}`;
}

/** The board's one-line summary: "2 need you · 1 review · 5 updates". */
export function boardSummary(counts: {
	needsYou: number;
	review: number;
	updates: number;
}): string {
	const parts = [
		counts.needsYou ? `${counts.needsYou} need you` : null,
		counts.review ? `${counts.review} review` : null,
		counts.updates ? `${counts.updates} ${counts.updates === 1 ? 'update' : 'updates'}` : null
	].filter((part) => part !== null);
	return parts.length ? parts.join(' · ') : 'Nothing waiting';
}
