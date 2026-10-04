import type { Refusal } from './reply';

export type AttachState = 'waiting' | 'uploading' | 'done' | 'failed';

/** One file picked for a reply, from the pick to its path in the text box. */
export interface Attached {
	key: number;
	/** The name the file is sent under. */
	name: string;
	size: number;
	/** Drawn as a thumbnail. */
	image: boolean;
	state: AttachState;
	/** 0 to 1, while it uploads. */
	progress: number;
	/** Why it failed: a short label. */
	error: string | null;
	/** A failed file that can be sent again as it is. */
	retry: boolean;
	/** What went into the text box for it, once it is on the Mac. */
	text: string | null;
}

export type AttachEvent =
	| { type: 'add'; key: number; name: string; size: number; image: boolean; max: number | null }
	| { type: 'start'; key: number }
	| { type: 'progress'; key: number; progress: number }
	| { type: 'done'; key: number; text: string }
	| { type: 'fail'; key: number; error: string; retry: boolean }
	| { type: 'retry'; key: number }
	| { type: 'requeue'; key: number }
	| { type: 'remove'; key: number }
	| { type: 'clear' };

const TOO_LARGE = 'Too large';

/** Whether `type` is one the phone can draw as a picture. */
export function isImage(type: string): boolean {
	return type.startsWith('image/');
}

/** A file over the Mac's limit is not sent. `max` null: the Mac named no limit. */
export function tooLarge(size: number, max: number | null): boolean {
	return max !== null && size > max;
}

const clamp = (value: number): number => Math.min(1, Math.max(0, value));

/** The list of attachments after `event`. The list given is not changed. */
export function attachReduce(items: readonly Attached[], event: AttachEvent): Attached[] {
	const change = (key: number, to: (item: Attached) => Attached): Attached[] =>
		items.map((item) => (item.key === key ? to(item) : item));
	switch (event.type) {
		case 'add': {
			const big = tooLarge(event.size, event.max);
			return [
				...items,
				{
					key: event.key,
					name: event.name,
					size: event.size,
					image: event.image,
					state: big ? 'failed' : 'waiting',
					progress: 0,
					error: big ? TOO_LARGE : null,
					retry: false,
					text: null
				}
			];
		}
		case 'start':
			return change(event.key, (item) => ({
				...item,
				state: 'uploading',
				progress: 0,
				error: null,
				retry: false
			}));
		case 'progress':
			return change(event.key, (item) =>
				item.state === 'uploading' ? { ...item, progress: clamp(event.progress) } : item
			);
		case 'done':
			return change(event.key, (item) => ({
				...item,
				state: 'done',
				progress: 1,
				text: event.text
			}));
		case 'fail':
			return change(event.key, (item) => ({
				...item,
				state: 'failed',
				error: event.error,
				retry: event.retry
			}));
		case 'retry':
			return change(event.key, (item) =>
				item.state === 'failed' && item.retry
					? { ...item, state: 'waiting', progress: 0, error: null, retry: false }
					: item
			);
		case 'requeue':
			// The thread was taking another write: the same file waits its turn again.
			return change(event.key, (item) =>
				item.state === 'uploading' ? { ...item, state: 'waiting', progress: 0 } : item
			);
		case 'remove':
			return items.filter((item) => item.key !== event.key);
		case 'clear':
			return [];
	}
}

/**
 * The file to send next: the first that waits, and only when none is on its
 * way. A thread takes one write at a time.
 */
export function nextUpload(items: readonly Attached[]): Attached | null {
	if (items.some((item) => item.state === 'uploading')) return null;
	return items.find((item) => item.state === 'waiting') ?? null;
}

/** Send has to wait: a file is on its way, or about to be. */
export function uploadsPending(items: readonly Attached[]): boolean {
	return items.some((item) => item.state === 'uploading' || item.state === 'waiting');
}

/** `draft` with a file's path at its end, and a space after it to type on from. */
export function insertPath(draft: string, text: string): string {
	if (draft === '') return `${text} `;
	return `${draft}${/\s$/.test(draft) ? '' : ' '}${text} `;
}

/**
 * `draft` without a file's path, if the path is still there as it was put in.
 * A path that was edited is the human's text now: it stays.
 */
export function removePath(draft: string, text: string): string {
	const at = draft.lastIndexOf(text);
	if (at < 0) return draft;
	const end = at + text.length;
	// A whole word, not the start of a longer path.
	if (at > 0 && !/\s/.test(draft[at - 1])) return draft;
	if (end < draft.length && !/\s/.test(draft[end])) return draft;
	// The space that came with it goes too.
	const after = draft[end] === ' ' ? end + 1 : end;
	return draft.slice(0, at) + draft.slice(after);
}

/** How often a file is sent again by itself when the thread was taking another write. */
export const BUSY_TRIES = 3;

/**
 * The thread was taking another write (a reply, or a file just stopped): the
 * file is not refused, it is only early. It goes again by itself a few times.
 */
export function busyRetry(refusal: Refusal | null, tries: number): boolean {
	return refusal?.status === 409 && refusal.code === 'busy' && tries < BUSY_TRIES;
}

/** The label on a file's tile, and whether sending it again can help. */
export function uploadFailure(
	refusal: Refusal | null,
	online: boolean
): { error: string; retry: boolean } {
	// No answer at all: the phone is offline, or the Mac is out of reach.
	if (!online || refusal === null) return { error: 'Offline', retry: true };
	if (refusal.status === 413) return { error: TOO_LARGE, retry: false };
	// Another write was in flight, or the Mac had a bad moment: the same file can go again.
	const retry = refusal.status === 409 || refusal.status >= 500;
	return { error: refusal.detail ?? 'Refused', retry };
}

const EXTENSIONS: Record<string, string> = {
	'image/png': 'png',
	'image/jpeg': 'jpg',
	'image/gif': 'gif',
	'image/webp': 'webp',
	'image/heic': 'heic',
	'image/tiff': 'tiff'
};

/** The name of the `n`th image pasted from the clipboard, which has none of its own. */
export function pastedName(n: number, type: string): string {
	return `pasted-${n}.${EXTENSIONS[type] ?? 'png'}`;
}

/** The state line of a tile. */
export function tileLabel(item: Attached): string {
	switch (item.state) {
		case 'waiting':
			return 'Waiting';
		case 'uploading':
			return `${Math.round(item.progress * 100)}%`;
		case 'done':
			return 'Attached';
		case 'failed':
			return item.error ?? 'Refused';
	}
}
