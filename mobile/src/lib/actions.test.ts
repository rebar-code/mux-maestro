import { describe, expect, it } from 'vitest';
import {
	actionTarget,
	killed,
	menuItems,
	menuTitle,
	refusalText,
	validName,
	type MenuTarget
} from './actions';
import type { Thread } from './types';

const thread = (id: string, over: Partial<Thread> = {}): Thread => ({
	id,
	host: 'localhost',
	hostColor: '#3291ff',
	local: true,
	session: 'acme-app',
	window: 1,
	name: 'checkout-fix',
	pane: '%1',
	panes: 1,
	command: 'claude',
	cwd: '/Users/me/code/acme-app',
	status: 'idle',
	since: null,
	idleStage: 'awake',
	lastPrompt: null,
	lastActivityAt: null,
	sessionActivity: 0,
	chat: true,
	...over
});

const labels = (target: MenuTarget, canKill: boolean): string[] =>
	menuItems(target, canKill).map((item) => item.label);

describe('menuItems', () => {
	it('lists each row kind and leaves the kills out without the switch', () => {
		const row: MenuTarget = { kind: 'thread', thread: thread('localhost:1') };
		expect(labels(row, true)).toEqual(['New Window', 'Rename Window…', 'Zoom Pane', 'Kill Window']);
		expect(labels(row, false)).toEqual(['New Window', 'Rename Window…', 'Zoom Pane']);
		const split: MenuTarget = { kind: 'thread', thread: thread('localhost:1', { panes: 2 }) };
		expect(labels(split, true)).toContain('Kill Pane');
		const session: MenuTarget = {
			kind: 'session',
			host: 'devbox',
			session: 'infra',
			thread: 'devbox:5'
		};
		expect(labels(session, true)).toEqual(['New Window', 'Rename…', 'Kill Session']);
		expect(labels(session, false)).toEqual(['New Window', 'Rename…']);
		expect(labels({ kind: 'host', host: 'devbox' }, true)).toEqual(['New Session…']);
	});

	it('titles the sheet with the row', () => {
		expect(menuTitle({ kind: 'thread', thread: thread('localhost:1') })).toBe(
			'acme-app · checkout-fix'
		);
		expect(
			menuTitle({ kind: 'session', host: 'devbox', session: 'infra', thread: 'devbox:5' })
		).toBe('infra');
	});

	it('names a session to the Mac by one of its threads', () => {
		expect(
			actionTarget({ kind: 'session', host: 'devbox', session: 'infra', thread: 'devbox:5' })
		).toEqual({ thread: 'devbox:5' });
		expect(actionTarget({ kind: 'thread', thread: thread('localhost:1') })).toEqual({
			thread: 'localhost:1'
		});
		expect(actionTarget({ kind: 'host', host: 'devbox' })).toBeNull();
	});
});

describe('killed', () => {
	const threads = [
		thread('localhost:1', { panes: 2 }),
		thread('localhost:2', { panes: 2 }),
		thread('localhost:3', { window: 2 }),
		thread('devbox:1', { host: 'devbox' })
	];

	it('names the threads a kill takes away', () => {
		const row: MenuTarget = { kind: 'thread', thread: threads[0] };
		expect(killed(row, 'kill-pane', threads).map((t) => t.id)).toEqual(['localhost:1']);
		expect(killed(row, 'kill-window', threads).map((t) => t.id)).toEqual([
			'localhost:1',
			'localhost:2'
		]);
		const session: MenuTarget = {
			kind: 'session',
			host: 'localhost',
			session: 'acme-app',
			thread: 'localhost:1'
		};
		expect(killed(session, 'kill-session', threads)).toHaveLength(3);
	});
});

describe('validName', () => {
	it('takes plain names and emoji', () => {
		for (const name of ['api', 'checkout fix', 'feat/login', '🌱 mux', '👩‍💻 dev', '日本語']) {
			expect(validName(name), name).toBe(true);
		}
	});

	it('refuses what tmux reads as a target, a flag or a key', () => {
		const bad = ['', '  ', 'a:b', 'a.b', '=x', '$1', '@2', '%3', '#(id)', '-t', 'a;b', 'a\nb'];
		for (const name of [...bad, 'a\u001b[31m', 'a‮b', 'a'.repeat(65)]) {
			expect(validName(name), JSON.stringify(name)).toBe(false);
		}
	});
});

describe('refusalText', () => {
	it('prefers the sentence the Mac sent', () => {
		expect(refusalText('unavailable', 'Could not reach tmux')).toBe('Could not reach tmux');
		expect(refusalText('exists', null)).toBe('Name is taken');
		expect(refusalText(null, null)).toBe('Failed');
	});
});
