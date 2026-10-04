import { describe, expect, it } from 'vitest';
import {
	maestroState,
	needCount,
	nextStop,
	panelHeight,
	panelStops,
	PEEK_BLOCK,
	pointCards,
	REASON_MAX,
	settlePanel
} from './panel';
import type { ManagerItem, Thread } from './types';

const HEIGHTS = panelStops(667, 150);

describe('panelStops', () => {
	it('gives closed, peek, half and full', () => {
		expect(HEIGHTS).toEqual([0, 150 + PEEK_BLOCK, 374, 667]);
	});

	it('keeps the stops in order when the keyboard leaves little room', () => {
		const [closed, peek, half, full] = panelStops(300, 190);
		expect(closed).toBe(0);
		expect(peek).toBe(294);
		expect(half).toBe(294);
		expect(full).toBe(300);
	});

	it('never makes the peek taller than the screen', () => {
		expect(panelStops(200, 190)).toEqual([0, 200, 200, 200]);
	});
});

describe('panelHeight', () => {
	it('follows the finger between the stops', () => {
		expect(panelHeight(HEIGHTS, 1, 40)).toBe(294);
		expect(panelHeight(HEIGHTS, 2, -100)).toBe(274);
	});

	it('opens from closed by the distance pulled', () => {
		expect(panelHeight(HEIGHTS, 0, 120)).toBe(120);
	});

	it('resists past full and stops at closed', () => {
		expect(panelHeight(HEIGHTS, 3, 100)).toBe(692);
		expect(panelHeight(HEIGHTS, 1, -900)).toBe(0);
	});
});

describe('settlePanel', () => {
	it('opens from closed on a short pull, and falls back on a shorter one', () => {
		expect(settlePanel(HEIGHTS, 0, 118, 0)).toBe(1);
		expect(settlePanel(HEIGHTS, 0, 40, 0)).toBe(0);
		expect(settlePanel(HEIGHTS, 1, -60, 0)).toBe(1);
		expect(settlePanel(HEIGHTS, 1, -100, 0)).toBe(0);
	});

	it('lands on the stop ahead after a slow release', () => {
		expect(settlePanel(HEIGHTS, 1, 20, 0)).toBe(1);
		expect(settlePanel(HEIGHTS, 1, 90, 0)).toBe(2);
		expect(settlePanel(HEIGHTS, 1, -200, 0)).toBe(0);
	});

	it('passes a stop on one long pull', () => {
		expect(settlePanel(HEIGHTS, 1, 380, 0)).toBe(3);
		expect(settlePanel(HEIGHTS, 0, 400, 0)).toBe(2);
		expect(settlePanel(HEIGHTS, 3, -600, 0)).toBe(0);
	});

	it('takes a flick to the next stop in its direction', () => {
		expect(settlePanel(HEIGHTS, 1, 12, 1)).toBe(2);
		expect(settlePanel(HEIGHTS, 2, -12, -1)).toBe(1);
		expect(settlePanel(HEIGHTS, 1, -12, -1)).toBe(0);
		expect(settlePanel(HEIGHTS, 0, 30, 1)).toBe(1);
	});

	it('keeps a flick inside the stops', () => {
		expect(settlePanel(HEIGHTS, 3, 30, 1)).toBe(3);
		expect(settlePanel(HEIGHTS, 0, 0, -1)).toBe(0);
	});
});

describe('nextStop', () => {
	it('steps down and wraps from full to the peek', () => {
		expect([1, 2, 3].map((stop) => nextStop(stop as 1 | 2 | 3))).toEqual([2, 3, 1]);
	});
});

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
