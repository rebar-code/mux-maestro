import { describe, expect, it } from 'vitest';
import {
	actionTarget,
	copyValue,
	isCopyKey,
	killed,
	menuItems,
	menuTitle,
	folderName,
	PROMPT_MAX,
	refusalText,
	START_ITEMS,
	startTitle,
	validName,
	validPrompt,
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

describe('copy items', () => {
	const AGENT = '0a1b2c3d-0000-4000-8000-000000000001';
	const row = thread('localhost:1', { agent: AGENT, window: 3, pane: '%12' });
	const copies = (target: MenuTarget, canAct: boolean): string[] =>
		menuItems(target, true, canAct)
			.filter((item) => isCopyKey(item.key))
			.map((item) => item.label);

	it('copies the session id and the tmux targets', () => {
		expect(copyValue('copy-session-id', row)).toBe(AGENT);
		expect(copyValue('copy-window', row)).toBe('acme-app:3');
		expect(copyValue('copy-pane', row)).toBe('%12');
	});

	it('offers the session id only for a pane that runs an agent', () => {
		const all = ['Copy Session ID', 'Copy tmux Window', 'Copy tmux Pane'];
		expect(copies({ kind: 'thread', thread: row }, true)).toEqual(all);
		const shell = thread('localhost:1', { agent: null });
		expect(copyValue('copy-session-id', shell)).toBeNull();
		expect(copies({ kind: 'thread', thread: shell }, true)).toEqual(all.slice(1));
	});

	it('is all a thread offers with session actions off', () => {
		expect(
			menuItems({ kind: 'thread', thread: row }, true, false).map((item) => item.label)
		).toEqual(['Copy Session ID', 'Copy tmux Window', 'Copy tmux Pane']);
		expect(menuItems({ kind: 'host', host: 'devbox' }, true, false)).toEqual([]);
		const session: MenuTarget = {
			kind: 'session',
			host: 'devbox',
			session: 'billing',
			thread: 'devbox:2'
		};
		expect(menuItems(session, true, false)).toEqual([]);
	});
});

describe('menuItems', () => {
	it('lists each row kind and leaves the kills out without the switch', () => {
		const row: MenuTarget = { kind: 'thread', thread: thread('localhost:1') };
		expect(labels(row, true)).toEqual([
			'Flag',
			'New Window…',
			'Rename Window…',
			'Archive Window',
			'Zoom Pane',
			'Copy tmux Window',
			'Copy tmux Pane',
			'Kill Window'
		]);
		// Archive stays without the kill switch: the Mac can undo it.
		expect(labels(row, false)).toEqual([
			'Flag',
			'New Window…',
			'Rename Window…',
			'Archive Window',
			'Zoom Pane',
			'Copy tmux Window',
			'Copy tmux Pane'
		]);
		const kept: MenuTarget = { kind: 'thread', thread: thread('localhost:1', { flagged: true }) };
		expect(labels(kept, false)[0]).toBe('Unflag');
		const split: MenuTarget = { kind: 'thread', thread: thread('localhost:1', { panes: 2 }) };
		expect(labels(split, true)).toContain('Kill Pane');
		const session: MenuTarget = {
			kind: 'session',
			host: 'devbox',
			session: 'infra',
			thread: 'devbox:5'
		};
		expect(labels(session, true)).toEqual(['New Window…', 'Rename…', 'Kill Session']);
		expect(labels(session, false)).toEqual(['New Window…', 'Rename…']);
		expect(labels({ kind: 'host', host: 'devbox' }, true)).toEqual(['New Session…']);
	});

	it('offers Claude, Codex and a terminal for a new window', () => {
		expect(START_ITEMS.map((item) => [item.kind, item.label])).toEqual([
			['claude', 'Claude'],
			['codex', 'Codex'],
			['terminal', 'Terminal']
		]);
		expect(startTitle({ kind: 'thread', thread: thread('localhost:1') })).toBe('acme-app');
		expect(
			startTitle({ kind: 'session', host: 'devbox', session: 'infra', thread: 'devbox:5' })
		).toBe('infra');
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

describe('validPrompt', () => {
	it('takes text, new lines and tabs, and no prompt at all', () => {
		for (const prompt of [
			'',
			'  ',
			'fix the login test',
			'it\'s $(id) `x`; \\ "q"',
			'a\nb\tc',
			'é 日本語 🌱'
		])
			expect(validPrompt(prompt), JSON.stringify(prompt)).toBe(true);
	});

	it('refuses a key press and a word the agent would read as an option', () => {
		for (const prompt of [
			'a\u001b[2J',
			'a\u0003',
			'a\u007f',
			'a\u009b',
			'a\rb',
			'--help',
			'  -p hi'
		])
			expect(validPrompt(prompt), JSON.stringify(prompt)).toBe(false);
	});

	it('counts the bytes of the quoted word, as the Mac does', () => {
		expect(validPrompt('a'.repeat(PROMPT_MAX - 2))).toBe(true);
		expect(validPrompt('a'.repeat(PROMPT_MAX - 1))).toBe(false);
		// A quote is four bytes, and so is a backslash.
		expect(validPrompt("'".repeat(224))).toBe(true);
		expect(validPrompt("'".repeat(225))).toBe(false);
		expect(validPrompt('\\'.repeat(225))).toBe(false);
		expect(validPrompt('é'.repeat(449))).toBe(true);
		expect(validPrompt('é'.repeat(450))).toBe(false);
	});
});

describe('folderName', () => {
	it('is the last step of a path', () => {
		expect(folderName('/home/me/code/acme-app')).toBe('acme-app');
		expect(folderName('/home/me')).toBe('me');
		expect(folderName('/')).toBe('/');
	});
});

describe('refusals of a spin-up', () => {
	it('say what was wrong', () => {
		expect(refusalText('bad_prompt', null)).toBe('Prompt not allowed');
		expect(refusalText('too_large', null)).toBe('Prompt too long');
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
