import { describe, expect, it } from 'vitest';
import { maestroDot, maestroState, needCount, pointCards, POINTS_MAX, REASON_MAX } from './panel';
import type { ManagerItem, Thread } from './types';

describe('maestroState', () => {
	it('is off without the capability, whatever the pane does', () => {
		expect(maestroState({ on: false, busy: true, status: 'waiting' })).toBe('off');
	});

	it('puts a question before work', () => {
		expect(maestroState({ on: true, busy: true, status: 'waiting' })).toBe('asks');
		expect(maestroState({ on: true, busy: true, status: 'idle' })).toBe('working');
		expect(maestroState({ on: true, busy: false, status: 'busy' })).toBe('working');
		expect(maestroState({ on: true, busy: false, status: 'idle' })).toBe('idle');
	});
});

describe('maestroDot', () => {
	it('has no dot while the Maestro is off', () => {
		expect(maestroDot('off', 'dozing')).toBeNull();
	});

	it('draws the dot a thread in that state has', () => {
		expect(maestroDot('asks', 'awake')).toEqual({
			dot: 'waiting',
			label: 'needs you',
			sleeps: false
		});
		expect(maestroDot('working', 'awake')).toEqual({
			dot: 'busy',
			label: 'running',
			sleeps: false
		});
		expect(maestroDot('idle', 'awake')).toEqual({ dot: 'idle', label: 'idle', sleeps: false });
		expect(maestroDot('idle', 'dozing')).toEqual({ dot: 'idle', label: 'sleeping', sleeps: true });
	});

	it('only an idle pane sleeps', () => {
		expect(maestroDot('working', 'dozing')?.sleeps).toBe(false);
		expect(maestroDot('asks', 'dozing')?.sleeps).toBe(false);
	});
});

const thread = (id: string, status: Thread['status']): Thread =>
	({ id, status, session: 'acme-app', name: 'checkout-fix' }) as Thread;
const point = (
	key: string | null,
	id: string | null,
	detail = 'needs your approval'
): ManagerItem => ({
	key,
	title: 'acme-app',
	detail,
	severity: 'blocked',
	at: 0,
	thread: id
});

describe('pointCards', () => {
	const threads = [thread('localhost:1', 'waiting'), thread('localhost:2', 'busy')];

	it('gives a live pointer its thread', () => {
		const [card] = pointCards([point('point:a', 'localhost:1')], threads);
		expect(card.thread?.id).toBe('localhost:1');
		expect(card.stale).toBeNull();
		expect(card.reason).toBe('needs your approval');
	});

	it('marks a session that no longer waits', () => {
		expect(pointCards([point('point:a', 'localhost:2')], threads)[0].stale).toBe('done');
	});

	it('marks a session that is gone, and one the Mac could not resolve', () => {
		expect(pointCards([point('point:a', 'localhost:9')], threads)[0]).toMatchObject({
			thread: null,
			stale: 'gone'
		});
		expect(pointCards([point('point:a', null)], threads)[0].stale).toBe('gone');
	});

	it('calls nothing closed before the thread list has loaded', () => {
		expect(pointCards([point('point:a', 'localhost:1')], null)[0].stale).toBeNull();
	});

	it('caps the reason and flattens it to one line', () => {
		const [card] = pointCards(
			[point('point:a', 'localhost:1', `a\n<b>b</b> ${'x'.repeat(300)}`)],
			threads
		);
		expect(card.reason.length).toBe(REASON_MAX);
		expect(card.reason.startsWith('a <b>b</b> x')).toBe(true);
		expect(card.reason.endsWith('…')).toBe(true);
	});

	it('removes zero-width and direction characters from the reason and the name', () => {
		const sly = {
			...point('point:a', null, 'needs\u202E lavorppa\u200B \u2066your\u2069'),
			title: 'acme\u200F-app'
		};
		const [card] = pointCards([sly], threads);
		expect(card.reason).toBe('needs lavorppa your');
		expect(card.title).toBe('acme-app');
	});

	it('lists no more than the cap', () => {
		const many = Array.from({ length: 300 }, (_, n) => point(`point:${n}`, 'localhost:1'));
		expect(pointCards(many, threads)).toHaveLength(POINTS_MAX);
	});

	it('drops a pointer with no key', () => {
		expect(pointCards([point(null, 'localhost:1')], threads)).toEqual([]);
	});
});

describe('needCount', () => {
	const threads = [thread('localhost:1', 'waiting'), thread('localhost:2', 'busy')];
	const waiting = [{ thread: threads[0] }];

	it('counts a session once when it waits and is pointed at', () => {
		expect(needCount(waiting, pointCards([point('point:a', 'localhost:1')], threads))).toBe(1);
	});

	it('leaves out stale pointers', () => {
		const cards = pointCards([point('point:a', 'localhost:2'), point('point:b', null)], threads);
		expect(needCount(waiting, cards)).toBe(1);
		expect(needCount([], cards)).toBe(0);
	});
});
