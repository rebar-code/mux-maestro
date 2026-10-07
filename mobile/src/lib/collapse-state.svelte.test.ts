import { describe, expect, it } from 'vitest';
import { Collapse, type KeyValueStore } from './collapse-state.svelte';
import type { Thread } from './types';

const KEY = 'mm.collapsed';

/** `localStorage`, in memory. */
class Memory implements KeyValueStore {
	items = new Map<string, string>();
	getItem(key: string): string | null {
		return this.items.get(key) ?? null;
	}
	setItem(key: string, value: string): void {
		this.items.set(key, value);
	}
}

/** Storage that is blocked: every use throws. */
const blocked = (): KeyValueStore => {
	throw new Error('storage is blocked');
};

const thread = (id: string, host: string, session: string): Thread =>
	({ id, host, session }) as Thread;

const THREADS = [
	thread('localhost:1', 'localhost', 'acme-app'),
	thread('localhost:4', 'localhost', 'acme-app'),
	thread('localhost:3', 'localhost', 'docs-site'),
	thread('devbox:2', 'devbox', 'billing')
];
const ACME = THREADS.slice(0, 2);
const DOCS = THREADS.slice(2, 3);

function make(threads: Thread[] | null = THREADS, stored?: string): [Collapse, Memory] {
	const memory = new Memory();
	if (stored !== undefined) memory.items.set(KEY, stored);
	return [
		new Collapse(
			() => memory,
			() => threads
		),
		memory
	];
}

describe('Collapse', () => {
	it('starts from what is stored', () => {
		const [collapse] = make(THREADS, '["localhost/acme-app"]');
		expect([...collapse.keys]).toEqual(['localhost/acme-app']);
		expect(make()[0].keys.size).toBe(0);
		expect(make(THREADS, 'not json')[0].keys.size).toBe(0);
	});

	it('a tap collapses an open session and stores it; a second tap expands it', () => {
		const [collapse, memory] = make();
		collapse.toggle('localhost/acme-app', false, ACME);
		expect(collapse.keys.has('localhost/acme-app')).toBe(true);
		expect(memory.getItem(KEY)).toBe('["localhost/acme-app"]');
		collapse.toggle('localhost/acme-app', true, ACME);
		expect(collapse.keys.size).toBe(0);
		expect(memory.getItem(KEY)).toBe('[]');
	});

	it('expanding all opens every session and stores it', () => {
		const [collapse, memory] = make(THREADS, '["localhost/acme-app","devbox/billing"]');
		collapse.expandAll();
		expect(collapse.keys.size).toBe(0);
		expect(memory.getItem(KEY)).toBe('[]');
	});

	it('saving drops sessions that no longer exist', () => {
		const [collapse, memory] = make(THREADS, '["localhost/gone","buildbox/old","devbox/billing"]');
		collapse.toggle('localhost/docs-site', false, DOCS);
		expect(memory.getItem(KEY)).toBe('["devbox/billing","localhost/docs-site"]');
		expect(collapse.keys.has('localhost/gone')).toBe(false);
	});

	it('keeps every key while the thread list has not loaded', () => {
		const [collapse, memory] = make(null, '["localhost/acme-app","devbox/billing"]');
		collapse.toggle('localhost/docs-site', false, DOCS);
		expect(memory.getItem(KEY)).toBe(
			'["devbox/billing","localhost/acme-app","localhost/docs-site"]'
		);
	});

	it('opening a thread expands its session and stores that', () => {
		const [collapse, memory] = make(THREADS, '["localhost/acme-app","devbox/billing"]');
		collapse.open('localhost:4');
		expect(collapse.opened).toBe('localhost:4');
		expect([...collapse.keys]).toEqual(['devbox/billing']);
		expect(memory.getItem(KEY)).toBe('["devbox/billing"]');
	});

	it('opening a thread before the list loads remembers it and stores nothing', () => {
		const [collapse, memory] = make(null, '["localhost/acme-app"]');
		collapse.open('localhost:4');
		expect(collapse.opened).toBe('localhost:4');
		expect([...collapse.keys]).toEqual(['localhost/acme-app']);
		expect(memory.getItem(KEY)).toBe('["localhost/acme-app"]');
	});

	it('a tap on another session does not let go of the opened thread', () => {
		// The open thread's session is stored as collapsed and shown open only
		// because the thread is open; folding another header must not undo that.
		const [collapse] = make(null, '["localhost/acme-app"]');
		collapse.open('localhost:4');
		collapse.toggle('localhost/docs-site', false, DOCS);
		expect(collapse.opened).toBe('localhost:4');
		collapse.toggle('localhost/docs-site', true, DOCS);
		expect(collapse.opened).toBe('localhost:4');
	});

	it("a tap on the opened thread's own session collapses it and lets go", () => {
		const [collapse] = make(null, '["localhost/acme-app"]');
		collapse.open('localhost:4');
		// It shows open (shut = false), so the tap collapses it.
		collapse.toggle('localhost/acme-app', false, ACME);
		expect(collapse.opened).toBe(null);
		expect(collapse.keys.has('localhost/acme-app')).toBe(true);
	});

	it('works for the visit when storage throws on read and on write', () => {
		const collapse = new Collapse(blocked, () => THREADS);
		expect(collapse.keys.size).toBe(0);
		expect(() => collapse.toggle('localhost/acme-app', false, ACME)).not.toThrow();
		expect(collapse.keys.has('localhost/acme-app')).toBe(true);
		expect(() => collapse.open('localhost:1')).not.toThrow();
		expect(collapse.keys.size).toBe(0);
	});

	it('keeps the state when only writing throws (storage full)', () => {
		const full: KeyValueStore = {
			getItem: () => '["devbox/billing"]',
			setItem: () => {
				throw new Error('quota exceeded');
			}
		};
		const collapse = new Collapse(
			() => full,
			() => THREADS
		);
		expect([...collapse.keys]).toEqual(['devbox/billing']);
		expect(() => collapse.toggle('localhost/acme-app', false, ACME)).not.toThrow();
		expect([...collapse.keys].sort()).toEqual(['devbox/billing', 'localhost/acme-app']);
	});
});
