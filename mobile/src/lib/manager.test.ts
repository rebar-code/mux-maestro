import { describe, expect, it } from 'vitest';
import { homeLines, needsYouCards } from './manager';
import type { ChatMessage, ManagerItem, Thread } from './types';

const chat = (...rows: [ChatMessage['role'], string][]): ChatMessage[] =>
	rows.map(([role, text], n) => ({ n, role, text }));

describe('homeLines', () => {
	it('shows the last three lines of the conversation, without tool rows', () => {
		const lines = homeLines(
			chat(
				['user', 'good morning'],
				['assistant', 'Morning.'],
				['user', 'what needs me?'],
				['tool', 'mux sessions'],
				['assistant', 'Two threads need you.']
			),
			null
		);
		expect(lines).toEqual([
			{ role: 'manager', text: 'Morning.' },
			{ role: 'user', text: 'what needs me?' },
			{ role: 'manager', text: 'Two threads need you.' }
		]);
	});

	it('puts the turn in flight after the chat', () => {
		const lines = homeLines(chat(['assistant', 'Morning.']), {
			prompt: 'what needs me?',
			reply: 'Two'
		});
		expect(lines).toEqual([
			{ role: 'manager', text: 'Morning.' },
			{ role: 'user', text: 'what needs me?' },
			{ role: 'manager', text: 'Two', live: true }
		]);
	});

	it('does not show a turn twice once the transcript has its prompt', () => {
		const lines = homeLines(
			chat(['assistant', 'Morning.'], ['user', 'what needs me?'], ['assistant', 'Two threads']),
			{ prompt: 'what needs me?', reply: 'Two threads need' }
		);
		expect(lines.map((line) => line.text)).toEqual([
			'Morning.',
			'what needs me?',
			'Two threads need'
		]);
	});

	it('keeps an older answer to the same question', () => {
		const lines = homeLines(
			chat(['user', 'what needs me?'], ['assistant', 'Nothing.'], ['user', 'thanks']),
			{ prompt: 'what needs me?', reply: '' }
		);
		expect(lines.map((line) => line.text)).toEqual(['thanks', 'what needs me?', '']);
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
