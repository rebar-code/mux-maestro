import { byteLength, TEXT_MAX_BYTES } from './compose';

/** A text that was typed and not sent, and when it was last changed. */
export interface Draft {
	text: string;
	at: number;
}

export type Drafts = Record<string, Draft>;

/** How many drafts are kept. The one changed longest ago gives way. */
export const DRAFTS_MAX = 20;
/** A draft that was not touched for this long is dropped: text does not sit on the phone for ever. */
export const DRAFT_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000;
/**
 * The largest draft that is written to storage. A text over the send limit
 * cannot be sent as it is, so it is kept for as long as the page lives only.
 */
export const DRAFT_MAX_BYTES = TEXT_MAX_BYTES + 1024;
/** The pause in the typing after which the drafts are written. */
export const DRAFT_SAVE_MS = 400;

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

/** `drafts` without the ones that are too old, or are not drafts at all. */
export function freshDrafts(drafts: Drafts, now: number): Drafts {
	const kept: Drafts = {};
	for (const [id, draft] of Object.entries(drafts)) {
		if (!draft || typeof draft.text !== 'string' || typeof draft.at !== 'number') continue;
		if (now - draft.at <= DRAFT_MAX_AGE_MS) kept[id] = draft;
	}
	return kept;
}

const KEY = 'mm.drafts';

type Store = Pick<Storage, 'getItem' | 'setItem' | 'removeItem'>;

/**
 * The drafts of every text box: read from storage once, kept in memory, and
 * written back after a pause in the typing, so a key press costs no parse and
 * no write. `flush` writes at once, for a page that is going away.
 */
export class DraftStore {
	private drafts: Drafts | null = null;
	private timer: ReturnType<typeof setTimeout> | undefined;
	private dirty = false;
	/** The last write did not get through: storage is full, or blocked. */
	failed = false;
	/** Called after each write with whether it got through. */
	onSaved: ((ok: boolean) => void) | null = null;

	constructor(private readonly storage: Store | null) {}

	private all(): Drafts {
		if (this.drafts) return this.drafts;
		let read: Drafts = {};
		try {
			const raw = this.storage?.getItem(KEY);
			const parsed: unknown = raw ? JSON.parse(raw) : {};
			if (parsed && typeof parsed === 'object') read = parsed as Drafts;
		} catch {
			// Unreadable: start with none.
		}
		this.drafts = freshDrafts(read, Date.now());
		return this.drafts;
	}

	/** The text left in the box of `id`. */
	load(id: string): string {
		return draftOf(this.all(), id);
	}

	/** Keep the box of `id`. Written to storage after a pause, or by `flush`. */
	save(id: string, text: string): void {
		const now = Date.now();
		this.drafts = putDraft(freshDrafts(this.all(), now), id, text, now);
		this.dirty = true;
		clearTimeout(this.timer);
		this.timer = setTimeout(() => this.flush(), DRAFT_SAVE_MS);
	}

	/** Write now. True when storage holds what memory holds (less the over-long ones). */
	flush(): boolean {
		clearTimeout(this.timer);
		if (!this.dirty) return !this.failed;
		const stored: Drafts = {};
		for (const [id, draft] of Object.entries(this.all())) {
			if (byteLength(draft.text) <= DRAFT_MAX_BYTES) stored[id] = draft;
		}
		let ok = false;
		try {
			if (this.storage) {
				if (Object.keys(stored).length) this.storage.setItem(KEY, JSON.stringify(stored));
				else this.storage.removeItem(KEY);
				ok = true;
			}
		} catch {
			// Full or blocked: the drafts last as long as the page. `failed` says so.
		}
		this.dirty = !ok;
		this.failed = !ok;
		this.onSaved?.(ok);
		return ok;
	}

	/** Forget every draft, here and in storage: the pairing ended or changed. */
	clear(): void {
		clearTimeout(this.timer);
		this.drafts = {};
		this.dirty = false;
		try {
			this.storage?.removeItem(KEY);
		} catch {
			// Nothing was stored that could be removed.
		}
	}
}

function browserStorage(): Store | null {
	try {
		return typeof localStorage === 'undefined' ? null : localStorage;
	} catch {
		return null;
	}
}

/** The drafts of this phone. */
export const drafts = new DraftStore(browserStorage());

/**
 * Attachment for the app root: write the drafts when the page goes to the
 * background or away, and mark the page when a write failed.
 */
export function keepDrafts(node: HTMLElement): () => void {
	const hidden = (): void => {
		if (document.visibilityState === 'hidden') drafts.flush();
	};
	const leaving = (): void => void drafts.flush();
	drafts.onSaved = (ok) => node.toggleAttribute('data-drafts-unsaved', !ok);
	document.addEventListener('visibilitychange', hidden);
	window.addEventListener('pagehide', leaving);
	return () => {
		drafts.onSaved = null;
		document.removeEventListener('visibilitychange', hidden);
		window.removeEventListener('pagehide', leaving);
	};
}
