import { describe, expect, it } from 'vitest';
import {
	BAR_KEYS,
	canAnswer,
	barKeys,
	CTRL_MS,
	ctrlReduce,
	filterCommands,
	isKeyName,
	KEY_QUEUE_MAX,
	liveLines,
	needsPrompt,
	nextWaiting,
	queuedLines,
	queueKey,
	refusalLabel,
	sendReduce,
	slashQuery,
	textRefusal,
	type QueuedKey,
	type Refusal,
	type SendStage
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
		// A sink that pastes gets the Paste key, first.
		expect(barKeys(true, true)).toHaveLength(15);
		expect(barKeys(true, true)[0].paste).toBe(true);
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

	it('switches off after one key of any other kind, and sends nothing', () => {
		for (const data of ['1', ' ', 'ab', '/', 'é', null])
			expect(ctrlReduce(true, { type: 'input', data })).toEqual({ on: false, key: null });
	});

	it('gives up after five seconds', () => {
		expect(CTRL_MS).toBe(5000);
	});

	it('does nothing while off', () => {
		expect(ctrlReduce(false, { type: 'input', data: 'c' })).toEqual({ on: false, key: null });
	});
});

describe('queueKey', () => {
	it('keeps the order and drops what does not fit', () => {
		let queue: QueuedKey[] = [];
		for (const key of ['Up', 'Up', 'Enter']) queue = queueKey(queue, key, null);
		expect(queue.map((entry) => entry.key)).toEqual(['Up', 'Up', 'Enter']);
		for (let i = 0; i < 20; i += 1) queue = queueKey(queue, 'Down', null);
		expect(queue).toHaveLength(KEY_QUEUE_MAX);
		expect(queue.slice(0, 3).map((entry) => entry.key)).toEqual(['Up', 'Up', 'Enter']);
	});

	it('does not change the queue it was given', () => {
		const queue: QueuedKey[] = [{ key: 'Up', prompt: null, terminal: false }];
		expect(queueKey(queue, 'Down', null)).toHaveLength(2);
		expect(queue).toHaveLength(1);
	});

	it('stores with each key the prompt id given at the tap', () => {
		// Down is tapped on card "a"; the card then becomes "b"; Enter is tapped
		// before the phone has seen "b", so it still names "a".
		let queue = queueKey([], 'Down', 'a');
		queue = queueKey(queue, 'Enter', 'a');
		queue = queueKey(queue, 'Enter', 'b');
		queue = queueKey(queue, 'Escape', null);
		expect(queue).toEqual([
			{ key: 'Down', prompt: 'a', terminal: false },
			{ key: 'Enter', prompt: 'a', terminal: false },
			{ key: 'Enter', prompt: 'b', terminal: false },
			{ key: 'Escape', prompt: null, terminal: false }
		]);
	});

	it('stores whether the terminal was on screen at the tap', () => {
		let queue = queueKey([], 'Enter', 'a', true);
		queue = queueKey(queue, 'Enter', 'a', false);
		expect(queue.map((entry) => entry.terminal)).toEqual([true, false]);
	});
});

describe('refused replies', () => {
	const refused = (code: string, more: Partial<Refusal> = {}): Refusal => ({
		status: 409,
		code,
		detail: null,
		...more
	});

	it('keeps the draft when the pane gave the text back', () => {
		expect(
			textRefusal(refused('not_sent', { cleared: true, detail: 'The pane started a turn' }))
		).toEqual({ note: 'The pane started a turn', keepDraft: true });
		expect(textRefusal(refused('not_sent', { cleared: true }))).toEqual({
			note: 'Not sent',
			keepDraft: true
		});
	});

	it('empties the box when the text is still in the pane', () => {
		expect(
			textRefusal(refused('not_sent', { cleared: false, detail: 'The pane started a turn' }))
		).toEqual({ note: 'Left in the pane', keepDraft: false });
	});

	it('keeps the draft on every other refusal', () => {
		expect(textRefusal(refused('no_input', { detail: 'Thread shows no input box' }))).toEqual({
			note: 'Thread shows no input box',
			keepDraft: true
		});
		expect(textRefusal(refused('no_input'))).toEqual({ note: 'No input box', keepDraft: true });
		expect(textRefusal(refused('busy'))).toEqual({ note: 'Busy', keepDraft: true });
		expect(textRefusal(null)).toEqual({ note: 'No answer', keepDraft: true });
	});

	it('asks for the prompt again when the pane waits on one', () => {
		expect(needsPrompt(refused('waiting'))).toBe(true);
		expect(needsPrompt(refused('stale'))).toBe(true);
		expect(needsPrompt(refused('unseen'))).toBe(true);
		expect(needsPrompt(refused('no_option'))).toBe(false);
		expect(needsPrompt(refused('not_sent', { reason: 'waiting' }))).toBe(true);
		expect(needsPrompt(refused('not_sent', { reason: 'busy' }))).toBe(false);
		expect(needsPrompt(refused('busy'))).toBe(false);
		expect(needsPrompt(refused('no_input'))).toBe(false);
		expect(needsPrompt({ status: 400, code: 'stale', detail: null })).toBe(false);
		expect(needsPrompt(null)).toBe(false);
	});

	it('labels a stale key', () => {
		expect(refusalLabel(refused('stale'), 'key')).toBe('Prompt changed');
		expect(refusalLabel(refused('no_option'), 'key')).toBe('Not a choice on the card');
		expect(refusalLabel(refused('unseen'), 'key')).toBe('Open the terminal to answer');
	});

	it('answers only with the options the pane has a key for', () => {
		for (const n of [1, 4, 9]) expect(canAnswer(n)).toBe(true);
		for (const n of [0, 10, 12, -1, 1.5, NaN]) expect(canAnswer(n)).toBe(false);
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

describe('sendReduce: the two-stage send', () => {
	const tap = (stage: SendStage, busy: boolean, text: boolean): ReturnType<typeof sendReduce> =>
		sendReduce(stage, { type: 'tap', busy, text });

	it('sends in one tap to an idle agent', () => {
		expect(tap('idle', false, true)).toEqual({ stage: 'idle', action: 'send' });
		// Nothing in the box: nothing to send.
		expect(tap('idle', false, false)).toEqual({ stage: 'idle', action: null });
	});

	it('queues on the first tap to a busy agent, and arms the interrupt', () => {
		expect(tap('idle', true, true)).toEqual({ stage: 'armed', action: 'queue' });
		// A second message while the first is queued goes the same way.
		expect(tap('queued', true, true)).toEqual({ stage: 'armed', action: 'queue' });
	});

	it('interrupts only on a tap of the armed button with an empty box', () => {
		expect(tap('armed', true, false)).toEqual({ stage: 'idle', action: 'interrupt' });
		// Text in the box is queued, armed or not: a second message never cuts the turn short.
		expect(tap('armed', true, true)).toEqual({ stage: 'armed', action: 'queue' });
		// Never from `idle` or `queued`, with text or without: one tap cannot interrupt.
		for (const stage of ['idle', 'queued'] as const)
			for (const text of [true, false]) expect(tap(stage, true, text).action).not.toBe('interrupt');
	});

	it('arms again on a tap of the queued button, and sends nothing', () => {
		expect(tap('queued', true, false)).toEqual({ stage: 'armed', action: null });
		// With nothing queued and nothing typed there is nothing to arm for.
		expect(tap('idle', true, false)).toEqual({ stage: 'idle', action: null });
	});

	it('disarms by itself after the timeout, back to queued', () => {
		expect(sendReduce('armed', { type: 'timeout' })).toEqual({ stage: 'queued', action: null });
		// A late timer changes nothing else.
		expect(sendReduce('queued', { type: 'timeout' })).toEqual({ stage: 'queued', action: null });
		expect(sendReduce('idle', { type: 'timeout' })).toEqual({ stage: 'idle', action: null });
	});

	it('disarms when the turn ends: the agent has the queued text', () => {
		for (const stage of ['idle', 'queued', 'armed'] as const)
			expect(sendReduce(stage, { type: 'turn-end' })).toEqual({ stage: 'idle', action: null });
	});

	it('never interrupts an agent that is idle by the time of the tap', () => {
		// The button was armed, the turn ended, and the tap came before the phone heard of it.
		expect(tap('armed', false, true)).toEqual({ stage: 'idle', action: 'send' });
		expect(tap('armed', false, false)).toEqual({ stage: 'idle', action: null });
		expect(tap('queued', false, true)).toEqual({ stage: 'idle', action: 'send' });
	});

	it('takes two taps, and no fewer, from typed text to an interrupt', () => {
		const first = tap('idle', true, true);
		expect(first.action).toBe('queue');
		expect(tap(first.stage, true, false).action).toBe('interrupt');
		// After the timeout it takes two again: arm, then interrupt.
		const dropped = sendReduce(first.stage, { type: 'timeout' }).stage;
		const again = tap(dropped, true, false);
		expect(again).toEqual({ stage: 'armed', action: null });
		expect(tap(again.stage, true, false).action).toBe('interrupt');
	});
});

describe('queuedLines', () => {
	const row = (n: number, role: ChatMessage['role'], text: string): ChatMessage => ({
		n,
		role,
		text
	});

	it('draws a queued text until the transcript holds it', () => {
		const queued = [{ text: 'use the new name', after: 40 }];
		const chat = [row(10, 'user', 'rename it'), row(40, 'assistant', 'Working on it.')];
		expect(queuedLines(chat, queued)).toEqual(['use the new name']);
		expect(queuedLines([...chat, row(52, 'user', 'use the new name')], queued)).toEqual([]);
	});

	it('is not fooled by the same words said before, or by the agent', () => {
		const queued = [{ text: 'again', after: 40 }];
		expect(queuedLines([row(10, 'user', 'again')], queued)).toEqual(['again']);
		expect(queuedLines([row(52, 'assistant', 'again')], queued)).toEqual(['again']);
	});

	it('keeps the order they were queued in', () => {
		const queued = [
			{ text: 'one', after: 40 },
			{ text: 'two', after: 40 }
		];
		expect(queuedLines([], queued)).toEqual(['one', 'two']);
		expect(queuedLines([row(52, 'user', 'one')], queued)).toEqual(['two']);
	});
});
