import { describe, expect, it } from 'vitest';
import { CARD_ACTIONS_MAX, isOpen, linkThread, parseCard } from './cards';
import { pointCards } from './panel';
import type { ManagerItem, Thread } from './types';

/** A card as the Mac sends it. */
function sent(change: Record<string, unknown> = {}): Record<string, unknown> {
	return {
		v: 1,
		id: 'a1b2c3',
		title: 'asks whether to run the migration',
		body: 'It adds two columns.',
		source: 'localhost:13',
		actions: [{ label: 'Yes' }, { label: 'No' }],
		link: '/t/localhost:13',
		answered: null,
		...change
	};
}

describe('parseCard', () => {
	it('reads a version 1 card', () => {
		expect(parseCard(sent())).toEqual({
			v: 1,
			id: 'a1b2c3',
			title: 'asks whether to run the migration',
			body: 'It adds two columns.',
			source: 'localhost:13',
			actions: [{ label: 'Yes' }, { label: 'No' }],
			link: '/t/localhost:13',
			answered: null
		});
	});

	it('reads a card with no body, no source, no link and no button', () => {
		const card = parseCard(sent({ body: null, source: null, link: null, actions: [] }));
		expect(card).toMatchObject({ body: null, source: null, link: null, actions: [] });
	});

	it('reads the answer that reached the pane', () => {
		const card = parseCard(sent({ answered: { label: 'Yes', at: 1_759_500_100 } }));
		expect(card?.answered).toEqual({ label: 'Yes', at: 1_759_500_100 });
	});

	it('refuses a version it does not know', () => {
		for (const v of [0, 2, '1', null, undefined]) expect(parseCard(sent({ v }))).toBeNull();
	});

	it('refuses what is not a card', () => {
		for (const value of [null, undefined, 'card', 7, [], [sent()]]) {
			expect(parseCard(value)).toBeNull();
		}
	});

	it('refuses a card with a field of the wrong kind', () => {
		for (const change of [
			{ id: '' },
			{ id: 7 },
			{ title: '' },
			{ title: '   ' },
			{ title: null },
			{ body: 7 },
			{ source: 13 },
			{ source: undefined },
			{ actions: null },
			{ actions: 'Yes' },
			{ actions: [{ label: '' }] },
			{ actions: [{ text: 'yes' }] },
			{ actions: ['Yes'] },
			{ answered: 'Yes' },
			{ answered: { label: 'Yes' } },
			{ answered: { at: 5 } }
		]) {
			expect(parseCard(sent(change)), JSON.stringify(change)).toBeNull();
		}
	});

	it('refuses more buttons than a card has room for', () => {
		const actions = Array.from({ length: CARD_ACTIONS_MAX + 1 }, (_, n) => ({ label: `A${n}` }));
		expect(parseCard(sent({ actions }))).toBeNull();
		expect(parseCard(sent({ actions: actions.slice(0, CARD_ACTIONS_MAX) }))?.actions).toHaveLength(
			CARD_ACTIONS_MAX
		);
	});

	it('refuses a link that leaves the app', () => {
		for (const link of [
			'https://evil.example.com/t/x',
			'//evil.example.com/t/x',
			'muxmaestro://open?session=acme-app',
			'javascript:alert(1)',
			'/t/',
			'/t/a/b',
			'/t/a?next=https://evil.example.com',
			'/settings',
			't/localhost:13',
			7
		]) {
			expect(parseCard(sent({ link })), String(link)).toBeNull();
		}
	});

	it('keeps the lines of a body and drops what cannot be seen', () => {
		const card = parseCard(sent({ body: 'one\u202E\n\n  two   words \n' + 'z'.repeat(400) }));
		expect(card?.body?.startsWith('one\ntwo words\nzzz')).toBe(true);
		expect(card?.body).toHaveLength(280);
		expect(card?.body?.endsWith('…')).toBe(true);
	});

	it('cuts a title and a label to one short line', () => {
		const card = parseCard(
			sent({
				title: `run\nthe\u200B migration ${'x'.repeat(200)}`,
				actions: [{ label: 'y'.repeat(60) }]
			})
		);
		expect(card?.title.startsWith('run the migration xxx')).toBe(true);
		expect(card?.title).toHaveLength(120);
		expect(card?.actions[0].label).toHaveLength(40);
	});
});

describe('linkThread', () => {
	it('gives the thread a route opens', () => {
		expect(linkThread('/t/localhost:13')).toBe('localhost:13');
		expect(linkThread('/t/dev%2Fbox%201:3')).toBe('dev/box 1:3');
	});

	it('gives nothing for any other link', () => {
		for (const link of [null, '', '/', '/t/', '/t/a/b', '/t/a#b', '/t/%E0%A4%A', 'https://x/t/a']) {
			expect(linkThread(link), String(link)).toBeNull();
		}
	});
});

describe('isOpen', () => {
	it('is open while a card has a button and no answer', () => {
		expect(isOpen(parseCard(sent()))).toBe(true);
		expect(isOpen(parseCard(sent({ actions: [] })))).toBe(false);
		expect(isOpen(parseCard(sent({ answered: { label: 'Yes', at: 5 } })))).toBe(false);
		expect(isOpen(null)).toBe(false);
	});
});

describe('pointCards with a card', () => {
	const thread = (status: Thread['status']): Thread =>
		({ id: 'localhost:13', session: 'acme-app', name: 'migration', status }) as Thread;
	const point = (card: unknown): ManagerItem => ({
		key: 'point:localhost:acme-app',
		title: 'acme-app',
		detail: 'asks whether to run the migration',
		severity: 'blocked',
		at: 1,
		thread: 'localhost:13',
		card
	});

	it('carries the card of a pointer, and none for a plain pointer', () => {
		expect(pointCards([point(sent())], [thread('idle')])[0].card?.id).toBe('a1b2c3');
		expect(pointCards([point(undefined)], [thread('idle')])[0].card).toBeNull();
		// A card this build cannot read is still a pointer.
		expect(pointCards([point(sent({ v: 2 }))], [thread('idle')])[0].card).toBeNull();
	});

	it('is not stale while its question is open, whatever the session does', () => {
		// The session asked in words and stopped: it is idle, and it still needs the user.
		expect(pointCards([point(sent())], [thread('idle')])[0].stale).toBeNull();
		// A plain pointer at the same session is done: it no longer waits.
		expect(pointCards([point(undefined)], [thread('idle')])[0].stale).toBe('done');
		// Answered: done, like a pointer whose session moved on.
		const answered = sent({ answered: { label: 'Yes', at: 5 } });
		expect(pointCards([point(answered)], [thread('busy')])[0].stale).toBe('done');
		// Its session is closed.
		expect(pointCards([point(sent())], [])[0].stale).toBe('gone');
	});
});
