import { describe, expect, it } from 'vitest';
import {
	BAR_KEYS,
	barKeys,
	ctrlReduce,
	filterCommands,
	isKeyName,
	liveLines,
	nextWaiting,
	refusalLabel,
	slashQuery
} from './reply';
import type { ChatMessage, Command, Thread } from './types';

const thread = (id: string, status: Thread['status'], since: number | null): Thread =>
	({ id, status, since, session: 'acme-app', name: id }) as Thread;

const command = (name: string): Command => ({ name, description: '', source: 'builtin' });

describe('key bar', () => {
	it('lists the keys in order', () => {
		expect(BAR_KEYS.map((key) => key.label)).toEqual([
			'Esc',
			'Tab',
			'Sh+Tab',
			'Ctrl',
			'Ctrl+C',
			'←',
			'↓',
			'↑',
			'→',
			'⏎',
			'/',
			'~',
			'|',
			'-'
		]);
	});

	it('maps each key to the name the Mac takes', () => {
		const sent = Object.fromEntries(
			BAR_KEYS.filter((key) => key.send).map((key) => [key.label, key.send])
		);
		expect(sent).toEqual({
			Esc: 'Escape',
			Tab: 'Tab',
			'Sh+Tab': 'BTab',
			'Ctrl+C': 'C-c',
			'←': 'Left',
			'↓': 'Down',
			'↑': 'Up',
			'→': 'Right',
			'⏎': 'Enter'
		});
	});

	it('sends only allowed names, and types the rest', () => {
		for (const key of BAR_KEYS) {
			if (key.send) expect(isKeyName(key.send)).toBe(true);
			expect([key.send, key.insert, key.ctrl].filter((v) => v !== undefined)).toHaveLength(1);
			expect(key.aria).not.toBe('');
		}
		expect(BAR_KEYS.filter((key) => key.insert).map((key) => key.insert)).toEqual([
			'/',
			'~',
			'|',
			'-'
		]);
	});

	it('knows the whitelist', () => {
		for (const key of ['Enter', 'Escape', 'BTab', 'C-a', 'C-z', '1', '9'])
			expect(isKeyName(key)).toBe(true);
		for (const key of ['', '0', '10', 'C-A', 'C-1', 'C-ab', 'F1', 'enter', 'a', '/'])
			expect(isKeyName(key)).toBe(false);
	});

	it('has only pane keys when there is no text box', () => {
		expect(barKeys(true)).toHaveLength(14);
		expect(barKeys(false).every((key) => key.send !== undefined)).toBe(true);
		expect(barKeys(false)).toHaveLength(9);
	});
});

describe('ctrlReduce', () => {
	it('toggles', () => {
		expect(ctrlReduce(false, { type: 'toggle' })).toEqual({ on: true, key: null });
		expect(ctrlReduce(true, { type: 'toggle' })).toEqual({ on: false, key: null });
	});

	it('turns the next letter into a control key and switches off', () => {
		expect(ctrlReduce(true, { type: 'input', data: 'r' })).toEqual({ on: false, key: 'C-r' });
		expect(ctrlReduce(true, { type: 'input', data: 'D' })).toEqual({ on: false, key: 'C-d' });
	});

	it('leaves other input as text and stays on', () => {
		for (const data of ['1', ' ', 'ab', '/', 'é', null])
			expect(ctrlReduce(true, { type: 'input', data })).toEqual({ on: true, key: null });
	});

	it('does nothing while off', () => {
		expect(ctrlReduce(false, { type: 'input', data: 'c' })).toEqual({ on: false, key: null });
	});
});

describe('slash', () => {
	it('gives the typed name while the box holds only a command', () => {
		expect(slashQuery('/')).toBe('');
		expect(slashQuery('/com')).toBe('com');
		expect(slashQuery('/commit ')).toBeNull();
		expect(slashQuery('/commit now')).toBeNull();
		expect(slashQuery('')).toBeNull();
		expect(slashQuery('a/b')).toBeNull();
		expect(slashQuery(' /c')).toBeNull();
	});

	it('puts prefix matches before substring matches', () => {
		const all = ['review', 'commit', 'compact', 'security-review', 'clear'].map(command);
		expect(filterCommands(all, '').map((c) => c.name)).toEqual(all.map((c) => c.name));
		expect(filterCommands(all, 'co').map((c) => c.name)).toEqual(['commit', 'compact']);
		expect(filterCommands(all, 'RE').map((c) => c.name)).toEqual(['review', 'security-review']);
		expect(filterCommands(all, 'zz')).toEqual([]);
	});
});

describe('nextWaiting', () => {
	const threads = [
		thread('a', 'idle', 10),
		thread('b', 'waiting', 300),
		thread('c', 'waiting', 100),
		thread('d', 'busy', 5),
		thread('e', 'waiting', null)
	];

	it('picks the thread that has waited longest', () => {
		expect(nextWaiting(threads, 'a')?.id).toBe('c');
	});

	it('has no bar when the open thread waits', () => {
		expect(nextWaiting(threads, 'b')).toBeNull();
	});

	it('has no bar when nothing waits', () => {
		expect(nextWaiting([thread('a', 'idle', 1), thread('d', 'busy', 2)], 'a')).toBeNull();
	});

	it('puts a thread with no time last', () => {
		expect(nextWaiting([thread('e', 'waiting', null), thread('b', 'waiting', 9)], 'x')?.id).toBe(
			'b'
		);
		expect(nextWaiting([thread('e', 'waiting', null)], 'x')?.id).toBe('e');
	});
});

describe('refusalLabel', () => {
	it('prefers the sentence the Mac sent', () => {
		expect(refusalLabel({ status: 409, code: 'busy', detail: 'The agent is working' })).toBe(
			'The agent is working'
		);
	});

	it('falls back to a short label', () => {
		expect(refusalLabel({ status: 409, code: 'busy', detail: null })).toBe('Busy');
		expect(refusalLabel({ status: 409, code: 'waiting', detail: null })).toBe(
			'Waiting on a prompt'
		);
		expect(refusalLabel({ status: 413, code: 'too_large', detail: null })).toBe('Too long');
		expect(refusalLabel({ status: 413, code: 'too_large', detail: null }, 'file')).toBe('Too big');
		expect(refusalLabel({ status: 400, code: 'bad_request', detail: null })).toBe('Cannot be sent');
		expect(refusalLabel({ status: 400, code: 'bad_key', detail: null }, 'key')).toBe(
			'Key not allowed'
		);
		expect(refusalLabel({ status: 404, code: null, detail: null })).toBe('Closed');
		expect(refusalLabel({ status: 403, code: 'disabled', detail: null })).toBe('Off on the Mac');
		expect(refusalLabel({ status: 503, code: 'unavailable', detail: null })).toBe('Not available');
		expect(refusalLabel(null)).toBe('No answer');
	});
});

describe('liveLines', () => {
	const chat = (...rows: [ChatMessage['role'], string][]): ChatMessage[] =>
		rows.map(([role, text], n) => ({ n, role, text }));

	it('draws nothing without a turn', () => {
		expect(liveLines(chat(['user', 'hi']), null)).toEqual({ prompt: false, reply: false });
	});

	it('draws both lines until the chat has them', () => {
		const turn = { prompt: 'run the tests', reply: 'Running' };
		expect(liveLines(chat(['user', 'hi'], ['assistant', 'Hello']), turn)).toEqual({
			prompt: true,
			reply: true
		});
		expect(liveLines(chat(['user', 'run the tests']), turn)).toEqual({
			prompt: false,
			reply: true
		});
		expect(liveLines(chat(['user', 'run the tests'], ['tool', 'x']), turn)).toEqual({
			prompt: false,
			reply: true
		});
		expect(liveLines(chat(['user', 'run the tests'], ['assistant', 'Running now']), turn)).toEqual({
			prompt: false,
			reply: false
		});
	});

	it('draws no empty reply', () => {
		expect(liveLines([], { prompt: 'x', reply: '' })).toEqual({ prompt: true, reply: false });
	});
});
