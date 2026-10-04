import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
	DRAFT_MAX_AGE_MS,
	DRAFT_MAX_BYTES,
	DRAFTS_MAX,
	DraftStore,
	draftOf,
	freshDrafts,
	putDraft,
	type Drafts
} from './drafts';

describe('putDraft', () => {
	it('keeps one per thread, and one for the manager', () => {
		let drafts: Drafts = {};
		drafts = putDraft(drafts, 'thread:localhost:7', 'fix the tests', 1);
		drafts = putDraft(drafts, 'thread:devbox:2', 'use option two', 2);
		drafts = putDraft(drafts, 'manager', 'what needs me?', 3);
		expect(draftOf(drafts, 'thread:localhost:7')).toBe('fix the tests');
		expect(draftOf(drafts, 'thread:devbox:2')).toBe('use option two');
		expect(draftOf(drafts, 'manager')).toBe('what needs me?');
		expect(draftOf(drafts, 'thread:none:1')).toBe('');
	});

	it('keeps line breaks as typed', () => {
		expect(draftOf(putDraft({}, 'manager', 'one\n\ntwo\n', 1), 'manager')).toBe('one\n\ntwo\n');
	});

	it('drops a draft that is emptied, as after a send', () => {
		let drafts = putDraft({}, 'manager', 'hello', 1);
		drafts = putDraft(drafts, 'manager', '', 2);
		expect(drafts).toEqual({});
		expect(putDraft({}, 'manager', '', 3)).toEqual({});
	});

	it('is bounded: the one changed longest ago gives way', () => {
		let drafts: Drafts = {};
		for (let n = 0; n < DRAFTS_MAX; n += 1) drafts = putDraft(drafts, `thread:${n}`, 'x', n);
		drafts = putDraft(drafts, 'thread:new', 'y', 1000);
		expect(Object.keys(drafts)).toHaveLength(DRAFTS_MAX);
		expect(draftOf(drafts, 'thread:0')).toBe('');
		expect(draftOf(drafts, 'thread:1')).toBe('x');
		expect(draftOf(drafts, 'thread:new')).toBe('y');
	});

	it('does not change the map it was given', () => {
		const drafts = putDraft({}, 'manager', 'hello', 1);
		putDraft(drafts, 'manager', '', 2);
		putDraft(drafts, 'thread:a', 'x', 3);
		expect(drafts).toEqual({ manager: { text: 'hello', at: 1 } });
	});
});

describe('freshDrafts', () => {
	it('drops drafts older than seven days', () => {
		const now = 10 * DRAFT_MAX_AGE_MS;
		const drafts: Drafts = {
			old: { text: 'stale', at: now - DRAFT_MAX_AGE_MS - 1 },
			edge: { text: 'just in', at: now - DRAFT_MAX_AGE_MS },
			young: { text: 'fresh', at: now - 1000 }
		};
		expect(Object.keys(freshDrafts(drafts, now)).sort()).toEqual(['edge', 'young']);
		expect(DRAFT_MAX_AGE_MS).toBe(7 * 24 * 60 * 60 * 1000);
	});

	it('drops what is not a draft', () => {
		const odd = { a: { text: 5, at: 1 }, b: null, c: { text: 'ok', at: 'x' } } as unknown as Drafts;
		expect(freshDrafts(odd, 2)).toEqual({});
	});
});

/** A storage that counts its writes and can be made to refuse them. */
function storage(initial: Record<string, string> = {}): Storage & {
	writes: number;
	reads: number;
	full: boolean;
	data: Record<string, string>;
} {
	const self = {
		data: { ...initial },
		writes: 0,
		reads: 0,
		full: false,
		getItem(key: string) {
			self.reads += 1;
			return self.data[key] ?? null;
		},
		setItem(key: string, value: string) {
			if (self.full) throw new DOMException('full', 'QuotaExceededError');
			self.writes += 1;
			self.data[key] = value;
		},
		removeItem(key: string) {
			self.writes += 1;
			delete self.data[key];
		}
	};
	return self as unknown as ReturnType<typeof storage>;
}

const stored = (box: ReturnType<typeof storage>): Drafts =>
	JSON.parse(box.data['mm.drafts'] ?? '{}') as Drafts;

describe('DraftStore', () => {
	beforeEach(() => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-10-01T12:00:00Z'));
	});
	afterEach(() => vi.useRealTimers());

	it('reads the storage once, and answers from memory after', () => {
		const box = storage({
			'mm.drafts': JSON.stringify({ manager: { text: 'hi', at: Date.now() } })
		});
		const drafts = new DraftStore(box);
		expect(drafts.load('manager')).toBe('hi');
		expect(drafts.load('manager')).toBe('hi');
		expect(drafts.load('thread:a')).toBe('');
		expect(box.reads).toBe(1);
	});

	it('writes after a pause in the typing, not on every key', () => {
		const box = storage();
		const drafts = new DraftStore(box);
		for (const text of ['h', 'he', 'hel', 'hell', 'hello']) {
			drafts.save('manager', text);
			vi.advanceTimersByTime(50);
		}
		// Typed, and at once readable from memory; nothing written yet.
		expect(drafts.load('manager')).toBe('hello');
		expect(box.writes).toBe(0);
		vi.advanceTimersByTime(1000);
		expect(box.writes).toBe(1);
		expect(draftOf(stored(box), 'manager')).toBe('hello');
	});

	it('writes at once when told to: the page is going away', () => {
		const box = storage();
		const drafts = new DraftStore(box);
		drafts.save('thread:a', 'half a thought');
		expect(box.writes).toBe(0);
		expect(drafts.flush()).toBe(true);
		expect(draftOf(stored(box), 'thread:a')).toBe('half a thought');
		// Nothing more to write when the pause ends.
		vi.advanceTimersByTime(5000);
		expect(box.writes).toBe(1);
	});

	it('keeps a draft that is too long to send in memory only', () => {
		const box = storage();
		const drafts = new DraftStore(box);
		drafts.save('thread:a', 'short');
		drafts.flush();
		const long = 'x'.repeat(DRAFT_MAX_BYTES + 1);
		drafts.save('thread:a', long);
		drafts.save('thread:b', 'é'.repeat(DRAFT_MAX_BYTES / 2));
		drafts.flush();
		expect(drafts.load('thread:a')).toBe(long);
		// Not stored, and the shorter text it replaced is not left behind as if current.
		expect(stored(box)['thread:a']).toBeUndefined();
		expect(draftOf(stored(box), 'thread:b')).toHaveLength(DRAFT_MAX_BYTES / 2);
		expect(DRAFT_MAX_BYTES).toBeGreaterThan(8192);
	});

	it('says when a save failed, and again when one worked', () => {
		const box = storage();
		const drafts = new DraftStore(box);
		const seen: boolean[] = [];
		drafts.onSaved = (ok) => seen.push(ok);
		box.full = true;
		drafts.save('manager', 'hello');
		expect(drafts.flush()).toBe(false);
		expect(drafts.failed).toBe(true);
		// The text is not lost while the page lives.
		expect(drafts.load('manager')).toBe('hello');
		box.full = false;
		drafts.save('manager', 'hello again');
		vi.advanceTimersByTime(1000);
		expect(drafts.failed).toBe(false);
		expect(seen).toEqual([false, true]);
		expect(draftOf(stored(box), 'manager')).toBe('hello again');
	});

	it('drops drafts older than seven days on load and on save', () => {
		const now = Date.now();
		const box = storage({
			'mm.drafts': JSON.stringify({
				old: { text: 'stale', at: now - DRAFT_MAX_AGE_MS - 1000 },
				young: { text: 'fresh', at: now - 1000 }
			})
		});
		const drafts = new DraftStore(box);
		expect(drafts.load('old')).toBe('');
		expect(drafts.load('young')).toBe('fresh');
		// Time passes with the app open: the young one ages out at the next save.
		vi.setSystemTime(now + DRAFT_MAX_AGE_MS + 5000);
		drafts.save('thread:a', 'new');
		drafts.flush();
		expect(Object.keys(stored(box))).toEqual(['thread:a']);
		expect(drafts.load('young')).toBe('');
	});

	it('forgets everything when the pairing ends or changes', () => {
		const box = storage();
		const drafts = new DraftStore(box);
		drafts.save('manager', 'hello');
		drafts.save('thread:a', 'x');
		drafts.flush();
		drafts.save('thread:b', 'not written yet');
		drafts.clear();
		expect(drafts.load('manager')).toBe('');
		expect(drafts.load('thread:b')).toBe('');
		expect(box.data['mm.drafts']).toBeUndefined();
		// The write that was waiting does not bring them back.
		vi.advanceTimersByTime(5000);
		expect(box.data['mm.drafts']).toBeUndefined();
	});

	it('works with no storage at all', () => {
		const drafts = new DraftStore(null);
		drafts.save('manager', 'hello');
		expect(drafts.load('manager')).toBe('hello');
		expect(drafts.flush()).toBe(false);
	});
});
