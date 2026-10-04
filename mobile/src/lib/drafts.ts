/** A text that was typed and not sent, and when it was last changed. */
export interface Draft {
	text: string;
	at: number;
}

export type Drafts = Record<string, Draft>;

/** How many drafts are kept. The one changed longest ago gives way. */
export const DRAFTS_MAX = 20;

/**
 * `drafts` with the draft of `id` set to `text`. An empty text removes it, so
 * a sent or emptied box leaves nothing behind. The map given is not changed.
 */
export function putDraft(
	drafts: Drafts,
	id: string,
	text: string,
	at: number,
	max = DRAFTS_MAX
): Drafts {
	const next = { ...drafts };
	if (text === '') {
		delete next[id];
		return next;
	}
	next[id] = { text, at };
	const ids = Object.keys(next);
	if (ids.length <= max) return next;
	// The oldest go first; the one just written always stays.
	const oldest = ids.filter((one) => one !== id).sort((a, b) => next[a].at - next[b].at);
	for (const gone of oldest.slice(0, ids.length - max)) delete next[gone];
	return next;
}

/** The draft of `id`, or an empty text. */
export function draftOf(drafts: Drafts, id: string): string {
	return drafts[id]?.text ?? '';
}

const KEY = 'mm.drafts';

function read(): Drafts {
	try {
		const raw = localStorage.getItem(KEY);
		const parsed: unknown = raw ? JSON.parse(raw) : {};
		return parsed && typeof parsed === 'object' ? (parsed as Drafts) : {};
	} catch {
		return {};
	}
}

/** The text left in the box of `id` on an earlier visit. */
export function loadDraft(id: string): string {
	return draftOf(read(), id);
}

/** Keep the box of `id` for the next visit: across threads, a reload, or the app closing. */
export function saveDraft(id: string, text: string): void {
	try {
		localStorage.setItem(KEY, JSON.stringify(putDraft(read(), id, text, Date.now())));
	} catch {
		// Storage is full or blocked: the draft lasts as long as the page.
	}
}
