/**
 * The math of the Maestro panel: a sheet that drops from the top edge over any
 * page. Kept free of the DOM so it is tested directly.
 */
import { clamp, SETTLE_VELOCITY } from './pager';
import type { ManagerItem, Thread } from './types';

/** Closed, peek, half, full. */
export type PanelStop = 0 | 1 | 2 | 3;
export type PanelHeights = readonly [number, number, number, number];

/** The chat the peek shows above its text box: about one block. */
export const PEEK_BLOCK = 104;
const HALF = 0.56;
const RUBBER = 0.25;
/** How much of the way to the next stop a slow drag must go to land on it. */
const COMMIT = 0.3;

/**
 * The panel's height at each stop. `viewport` is the height the app has (less
 * with the keyboard open); `chrome` is what the panel always draws: its head,
 * its text box and its grabber.
 */
export function panelStops(viewport: number, chrome: number): PanelHeights {
	const full = Math.max(0, Math.floor(viewport));
	const peek = Math.min(Math.round(chrome + PEEK_BLOCK), full);
	const half = clamp(Math.round(viewport * HALF), peek, full);
	return [0, peek, half, full];
}

/** The panel's height while a finger holds it `down` pixels below its stop. */
export function panelHeight(heights: PanelHeights, stop: PanelStop, down: number): number {
	const full = heights[3];
	const wanted = heights[stop] + down;
	// Past the full stop it resists; above closed there is nothing to push.
	if (wanted > full) return full + (wanted - full) * RUBBER;
	return Math.max(wanted, 0);
}

/**
 * The stop a released drag lands on. A flick goes to the next stop in its
 * direction from where the panel is; a slow release goes on to the stop ahead
 * once it is a third of the way there, so one long pull can pass a stop. `vy` is positive going down.
 */
export function settlePanel(
	heights: PanelHeights,
	stop: PanelStop,
	down: number,
	vy: number
): PanelStop {
	const at = heights[stop] + down;
	const stops: PanelStop[] = [0, 1, 2, 3];
	if (Math.abs(vy) >= SETTLE_VELOCITY) {
		if (vy > 0) return stops.find((s) => heights[s] > at + 1) ?? 3;
		return stops.findLast((s) => heights[s] < at - 1) ?? 0;
	}
	// Between two stops: a pull of a third of the way goes on, less falls back.
	const upper = stops.find((s) => heights[s] > at) ?? 3;
	const lower = stops.findLast((s) => heights[s] <= at) ?? 0;
	if (upper <= lower) return lower;
	const part = (at - heights[lower]) / (heights[upper] - heights[lower]);
	if (down > 0) return part >= COMMIT ? upper : lower;
	return part <= 1 - COMMIT ? lower : upper;
}

/** The grabber's tap: one stop down, and from full back to the peek. */
export function nextStop(stop: PanelStop): PanelStop {
	return stop >= 3 ? 1 : ((stop + 1) as PanelStop);
}

/** What the header button shows. */
export type MaestroState = 'off' | 'asks' | 'working' | 'idle';

export function maestroState(input: { on: boolean; busy: boolean; status: string }): MaestroState {
	if (!input.on) return 'off';
	// A question on the Maestro's own pane comes before its work.
	if (input.status === 'waiting') return 'asks';
	return input.busy || input.status === 'busy' ? 'working' : 'idle';
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
}

/** The most pointers the board lists. The Mac caps them too. */
export const POINTS_MAX = 20;

/** Zero-width and direction characters: they can hide or reorder what a line says. */
const UNSEEN = /[\u200B-\u200F\u202A-\u202E\u2066-\u2069]/g;

function capped(text: string, max = REASON_MAX): string {
	const flat = text.replace(UNSEEN, '').replace(/\s+/g, ' ').trim();
	return flat.length > max ? `${flat.slice(0, max - 1)}…` : flat;
}

/**
 * The Maestro's pointers as cards. `threads` is null until the list has
 * loaded: nothing is called closed before that.
 */
export function pointCards(points: ManagerItem[], threads: Thread[] | null): PointCard[] {
	return points.slice(0, POINTS_MAX).flatMap((point) => {
		if (point.key === null) return [];
		const thread = threads?.find((row) => row.id === point.thread) ?? null;
		const stale = thread ? (thread.status === 'waiting' ? null : 'done') : threads ? 'gone' : null;
		return [
			{ key: point.key, thread, title: capped(point.title), reason: capped(point.detail), stale }
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
