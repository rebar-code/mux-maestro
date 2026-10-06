import type { VoiceEnd } from '../types';

/**
 * A take the Mac has not confirmed. It stays on this phone, audio and all,
 * until the Mac says its text is in the chat, or the human discards it.
 */
export interface KeptTake {
	/** Names the take to the Mac, so a take it already sent is not typed twice. */
	id: string;
	/** Where it goes: `manager`, or a thread's id. */
	target: string;
	at: number;
	seconds: number;
	wav: ArrayBuffer;
	/** What the Mac heard, once it said so. Sent again in place of the audio. */
	text: string | null;
}

/** Where the kept takes are written, so they outlive the page. */
export interface TakeStore {
	all(): Promise<KeptTake[]>;
	put(take: KeptTake): Promise<void>;
	remove(id: string): Promise<void>;
}

/** What a send came to, for the take it carried. */
export type Verdict = 'sent' | 'keep' | 'drop';

/**
 * The end of a take's stream. `empty` is a take with no words in it: there is
 * nothing to send again. `failed`, `refused`, `unreachable` and a stream that
 * ended without a reply never reached the chat.
 */
export function endVerdict(end: VoiceEnd, sent: boolean): Verdict {
	if (sent) return 'sent';
	if (end.outcome === 'empty') return 'drop';
	// A Mac that sends no `sent` event: these two ends are told after the send.
	if (end.outcome === 'done' || end.outcome === 'permission') return 'sent';
	return 'keep';
}

/** The Mac's words for audio it cannot use. */
const UNUSABLE = ['bad_audio', 'too_short', 'too_long'];

/**
 * A send the Mac refused, or that never reached it. Audio the Mac cannot use
 * (not a recording, too short, too long) is refused the same way every time,
 * so it is not kept. Everything else can work on a later try.
 */
export function errorVerdict(error: unknown): Verdict {
	const code = (error as { code?: unknown } | null)?.code;
	return typeof code === 'string' && UNUSABLE.includes(code) ? 'drop' : 'keep';
}

export function newTake(target: string, wav: ArrayBuffer, seconds: number, at: number): KeptTake {
	return { id: crypto.randomUUID(), target, at, seconds, wav, text: null };
}

/** `m:ss`, for the row of a kept take. */
export function takeLength(seconds: number): string {
	const whole = Math.max(1, Math.round(seconds));
	return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, '0')}`;
}

const DB = 'mm.voice';
const STORE = 'takes';

function open(): Promise<IDBDatabase> {
	return new Promise((resolve, reject) => {
		const request = indexedDB.open(DB, 1);
		request.onupgradeneeded = () => request.result.createObjectStore(STORE, { keyPath: 'id' });
		request.onsuccess = () => resolve(request.result);
		request.onerror = () => reject(request.error);
		request.onblocked = () => reject(new Error('blocked'));
	});
}

function done<T>(request: IDBRequest<T>): Promise<T> {
	return new Promise((resolve, reject) => {
		request.onsuccess = () => resolve(request.result);
		request.onerror = () => reject(request.error);
	});
}

/**
 * The takes in IndexedDB: it holds audio, and it outlives a reload and an app
 * restart. Writes run one after the other, so a take that is confirmed right
 * after it was written is not written back. A phone without storage (private
 * mode) keeps its takes for as long as the page lives.
 */
export function phoneTakes(): TakeStore {
	let db: Promise<IDBDatabase> | null = null;
	let last: Promise<unknown> = Promise.resolve();
	/**
	 * One write, done when it is on the phone. It is committed at once, not
	 * when the browser gets round to it: the page may be gone a moment later.
	 */
	const write = async (change: (store: IDBObjectStore) => void): Promise<void> => {
		db ??= open();
		const transaction = (await db).transaction(STORE, 'readwrite');
		const written = new Promise<void>((resolve, reject) => {
			transaction.oncomplete = () => resolve();
			transaction.onerror = () => reject(transaction.error);
			transaction.onabort = () => reject(transaction.error);
		});
		change(transaction.objectStore(STORE));
		transaction.commit?.();
		await written;
	};
	const queued = <T>(work: () => Promise<T>, fallback: T): Promise<T> => {
		const next = last.then(work).catch(() => fallback);
		last = next;
		return next;
	};
	return {
		all: () =>
			queued(async () => {
				db ??= open();
				const store = (await db).transaction(STORE, 'readonly').objectStore(STORE);
				const takes = await done<KeptTake[]>(store.getAll());
				return takes.sort((a, b) => a.at - b.at);
			}, []),
		put: (take) => queued(() => write((store) => store.put(take)), undefined),
		remove: (id) => queued(() => write((store) => store.delete(id)), undefined)
	};
}
