/**
 * What the Maestro's button and board show. Kept free of the DOM so it is
 * tested directly.
 */
import { capped, isOpen, parseCard, type ActionCard } from './cards';
import type { IdleStage, ManagerItem, Thread } from './types';

/** What the header button shows. */
export type MaestroState = 'off' | 'asks' | 'working' | 'idle';

export function maestroState(input: { on: boolean; busy: boolean; status: string }): MaestroState {
	if (!input.on) return 'off';
	// A question on the Maestro's own pane comes before its work.
	if (input.status === 'waiting') return 'asks';
	return input.busy || input.status === 'busy' ? 'working' : 'idle';
}

/**
 * The Maestro's row in the sidebar: the dot a thread in that state has, and
 * the word for it. `null`: the Maestro is off, there is no dot. Only an idle
 * pane sleeps.
 */
export function maestroDot(
	state: MaestroState,
	idleStage: IdleStage
): { dot: 'waiting' | 'busy' | 'idle'; label: string; sleeps: boolean } | null {
	if (state === 'off') return null;
	if (state === 'asks') return { dot: 'waiting', label: 'needs you', sleeps: false };
	if (state === 'working') return { dot: 'busy', label: 'running', sleeps: false };
	const sleeps = idleStage === 'dozing';
	return { dot: 'idle', label: sleeps ? 'sleeping' : 'idle', sleeps };
}

/** The longest reason a pointer shows. The Mac caps it too; this text is not trusted. */
export const REASON_MAX = 120;

/** A session the Maestro points at, as a card. */
export interface PointCard {
	key: string;
	/** The session's thread, while the thread list has it. */
	thread: Thread | null;
	/** The session's name as the Maestro wrote it, for a thread that is gone. */
	title: string;
	reason: string;
	/** `gone`: the session is closed. `done`: it no longer waits. */
	stale: 'gone' | 'done' | null;
	/** The pointer's buttons, when the Maestro gave it any. */
	card: ActionCard | null;
}

/** The most pointers the board lists. The Mac caps them too. */
export const POINTS_MAX = 20;

/**
 * The Maestro's pointers as cards. `threads` is null until the list has
 * loaded: nothing is called closed before that.
 */
export function pointCards(points: ManagerItem[], threads: Thread[] | null): PointCard[] {
	return points.slice(0, POINTS_MAX).flatMap((point) => {
		if (point.key === null) return [];
		const thread = threads?.find((row) => row.id === point.thread) ?? null;
		const card = parseCard(point.card);
		// A card asks in words, so its session can be idle and still need the user.
		const asks = thread?.status === 'waiting' || isOpen(card);
		const stale = thread ? (asks ? null : 'done') : threads ? 'gone' : null;
		return [
			{
				key: point.key,
				thread,
				title: capped(point.title, REASON_MAX),
				reason: capped(point.detail, REASON_MAX),
				stale,
				card
			}
		];
	});
}

/** How many sessions need the user: the ones that wait, and live pointers at others. */
export function needCount(waiting: { thread: Thread }[], points: PointCard[]): number {
	const ids = new Set(waiting.map((card) => card.thread.id));
	const more = points.filter(
		(card) => card.stale === null && !(card.thread && ids.has(card.thread.id))
	);
	return ids.size + more.length;
}
