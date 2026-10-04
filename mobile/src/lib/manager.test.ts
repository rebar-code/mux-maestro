import { describe, expect, it } from 'vitest';
import {
	boardSummary,
	elapsedLabel,
	needsYouCards,
	pendingPrompt,
	PHRASE_SECONDS,
	THINKING_PHRASES,
	thinkingText
} from './manager';
import type { ChatMessage, ManagerItem, Thread } from './types';

const chat = (...rows: [ChatMessage['role'], string][]): ChatMessage[] =>
	rows.map(([role, text], n) => ({ n, role, text }));

describe('pendingPrompt', () => {
	it('is the prompt until the chat holds it', () => {
		expect(pendingPrompt(null, chat(['user', 'hi']), -1)).toBeNull();
		expect(pendingPrompt('what needs me?', null, -1)).toBe('what needs me?');
		expect(pendingPrompt('what needs me?', chat(['assistant', 'Morning.']), 0)).toBe(
			'what needs me?'
		);
		expect(
			pendingPrompt(
				'what needs me?',
				chat(['assistant', 'Morning.'], ['user', 'what needs me?']),
				0
			)
		).toBeNull();
	});

	it('does not take an older turn with the same words for this one', () => {
		const rows = chat(['user', 'what needs me?'], ['assistant', 'Nothing.']);
		expect(pendingPrompt('what needs me?', rows, 1)).toBe('what needs me?');
		expect(
			pendingPrompt('what needs me?', [...rows, { n: 2, role: 'user', text: 'what needs me?' }], 1)
		).toBeNull();
	});
});

describe('thinkingText', () => {
	it("shows the pane's own spinner line when there is one", () => {
		expect(thinkingText('Incubating… 4m 48s', 3)).toBe('Incubating… 4m 48s');
	});

	it('else rotates through phrases, each with the time so far', () => {
		expect(thinkingText(null, 0)).toBe(`${THINKING_PHRASES[0]}… 0s`);
		expect(thinkingText(null, PHRASE_SECONDS - 1)).toBe(
			`${THINKING_PHRASES[0]}… ${PHRASE_SECONDS - 1}s`
		);
		expect(thinkingText(null, PHRASE_SECONDS)).toBe(`${THINKING_PHRASES[1]}… ${PHRASE_SECONDS}s`);
		const round = PHRASE_SECONDS * THINKING_PHRASES.length;
		expect(thinkingText(null, round)).toBe(`${THINKING_PHRASES[0]}… ${elapsedLabel(round)}`);
		expect(thinkingText('', 5)).toContain('… 5s');
		expect(new Set(THINKING_PHRASES).size).toBeGreaterThan(3);
	});

	it('writes the time as the agent does', () => {
		expect(elapsedLabel(0)).toBe('0s');
		expect(elapsedLabel(48)).toBe('48s');
		expect(elapsedLabel(288)).toBe('4m 48s');
		expect(elapsedLabel(3723)).toBe('1h 2m 3s');
		expect(elapsedLabel(3600)).toBe('1h 0m 0s');
		expect(elapsedLabel(-4)).toBe('0s');
	});
});

describe('boardSummary', () => {
	it('names what the board holds, and leaves out what it does not', () => {
		expect(boardSummary({ needsYou: 2, review: 1, updates: 5 })).toBe(
			'2 need you · 1 review · 5 updates'
		);
		expect(boardSummary({ needsYou: 0, review: 1, updates: 1 })).toBe('1 review · 1 update');
		expect(boardSummary({ needsYou: 0, review: 0, updates: 0 })).toBe('Nothing waiting');
	});
});

describe('needsYouCards', () => {
	const thread = (id: string, status: Thread['status']): Thread =>
		({ id, status, session: 'acme-app', name: id }) as Thread;
	const item = (id: string | null, detail: string): ManagerItem => ({
		key: null,
		title: '',
		detail,
		severity: null,
		at: 0,
		thread: id
	});

	it('lists waiting threads with the reason the manager has', () => {
		const cards = needsYouCards(
			[
				thread('localhost:1', 'waiting'),
				thread('localhost:2', 'busy'),
				thread('devbox:3', 'waiting')
			],
			[item('localhost:1', 'Permission · Bash'), item(null, 'Question'), item('localhost:2', 'x')]
		);
		expect(cards.map((card) => [card.thread.id, card.why])).toEqual([
			['localhost:1', 'Permission · Bash'],
			['devbox:3', null]
		]);
	});
});
