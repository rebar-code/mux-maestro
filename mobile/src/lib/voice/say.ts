/**
 * The play button under an agent's message: which message is read aloud, and
 * what a tap does to it. One message at a time, on this phone.
 */

/** A message of a pane's chat: the pane (`manager`, or a thread's id) and the row's `n`. */
export interface SayKey {
	target: string;
	n: number;
}

/** What a play button shows: at rest, waiting for its first audio, or reading. */
export type SayState = 'idle' | 'loading' | 'playing';

export const sameMessage = (a: SayKey | null, b: SayKey): boolean =>
	a !== null && a.target === b.target && a.n === b.n;

/**
 * A tap on the button of `tapped` while `now` is read (or nothing is).
 * Whatever is read stops first, so two messages never talk over each other.
 * A tap on the message that is read is its Stop: nothing starts.
 */
export function sayTap(
	now: SayKey | null,
	tapped: SayKey
): { stop: boolean; start: SayKey | null } {
	return { stop: now !== null, start: sameMessage(now, tapped) ? null : tapped };
}

/**
 * What the button of `key` shows. Only the message that is read shows
 * anything but Play, and it shows the progress sign until audio plays: the
 * Mac takes seconds over a long message, and the button must not look dead.
 */
export function sayState(now: SayKey | null, key: SayKey, speaking: boolean): SayState {
	if (!sameMessage(now, key)) return 'idle';
	return speaking ? 'playing' : 'loading';
}
