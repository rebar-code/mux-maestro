/** How a live terminal's socket stands. `off`: the captured view shows. */
export type LiveState = 'off' | 'connecting' | 'live' | 'reconnecting';

/** Tries in a row, with no screen from any of them, before the view falls back. */
export const MAX_TRIES = 5;

const FIRST_DELAY = 500;
const MAX_DELAY = 8000;

/**
 * Close codes after which another try would end the same way: the token is
 * wrong, the switch is off, the pane is not there, the socket was idle, a
 * newer socket of this phone took its place, the Mac has no tmux for it.
 */
const FINAL = new Set([4401, 4403, 4404, 4408, 4409, 4503]);

export function isFinal(code: number): boolean {
	return FINAL.has(code);
}

/** The wait before try number `tries` (0 for the first retry): it doubles, to a cap. */
export function retryDelay(tries: number): number {
	return Math.min(FIRST_DELAY * 2 ** Math.max(0, tries), MAX_DELAY);
}

export type Next = { retry: number } | { stop: true };

/**
 * What to do when the socket closed with `code`, after `tries` tries in a row
 * that showed no screen.
 */
export function afterClose(code: number, tries: number): Next {
	if (isFinal(code) || tries >= MAX_TRIES) return { stop: true };
	return { retry: retryDelay(tries) };
}

export type ServerMessage =
	{ type: 'ready'; cols: number; rows: number } | { type: 'size'; cols: number; rows: number };

const whole = (value: unknown): value is number =>
	typeof value === 'number' && Number.isInteger(value) && value >= 1 && value <= 1000;

/** A text message from the Mac, or null when it is not one this app knows. */
export function serverMessage(raw: string): ServerMessage | null {
	let data: unknown;
	try {
		data = JSON.parse(raw);
	} catch {
		return null;
	}
	if (typeof data !== 'object' || data === null) return null;
	const { type, cols, rows } = data as Record<string, unknown>;
	if ((type !== 'ready' && type !== 'size') || !whole(cols) || !whole(rows)) return null;
	return { type, cols, rows };
}
