import { describe, expect, it } from 'vitest';
import { draftOf, DRAFTS_MAX, putDraft, type Drafts } from './drafts';

describe('drafts', () => {
	it('keeps one per thread, and one for the manager', () => {
		let drafts: Drafts = {};
		drafts = putDraft(drafts, 'thread:localhost:7', 'fix the tests', 1);
		drafts = putDraft(drafts, 'thread:devbox:2', 'use option two', 2);
		drafts = putDraft(drafts, 'manager', 'what needs me?', 3);
		expect(draftOf(drafts, 'thread:localhost:7')).toBe('fix the tests');
		expect(draftOf(drafts, 'thread:devbox:2')).toBe('use option two');
		expect(draftOf(drafts, 'manager')).toBe('what needs me?');
		expect(draftOf(drafts, 'thread:none:1')).toBe('');
	});

	it('keeps line breaks as typed', () => {
		const drafts = putDraft({}, 'manager', 'one\n\ntwo\n', 1);
		expect(draftOf(drafts, 'manager')).toBe('one\n\ntwo\n');
	});

	it('drops a draft that is emptied, as after a send', () => {
		let drafts = putDraft({}, 'manager', 'hello', 1);
		drafts = putDraft(drafts, 'manager', '', 2);
		expect(drafts).toEqual({});
		// Emptying one that was never kept is nothing.
		expect(putDraft({}, 'manager', '', 3)).toEqual({});
	});

	it('is bounded: the one changed longest ago gives way', () => {
		let drafts: Drafts = {};
		for (let n = 0; n < DRAFTS_MAX; n += 1) drafts = putDraft(drafts, `thread:${n}`, 'x', n);
		expect(Object.keys(drafts)).toHaveLength(DRAFTS_MAX);
		drafts = putDraft(drafts, 'thread:new', 'y', 1000);
		expect(Object.keys(drafts)).toHaveLength(DRAFTS_MAX);
		expect(draftOf(drafts, 'thread:0')).toBe('');
		expect(draftOf(drafts, 'thread:1')).toBe('x');
		expect(draftOf(drafts, 'thread:new')).toBe('y');
		// Writing an old one again makes it the newest: another goes.
		drafts = putDraft(drafts, 'thread:1', 'z', 2000);
		drafts = putDraft(drafts, 'thread:newer', 'w', 3000);
		expect(draftOf(drafts, 'thread:1')).toBe('z');
		expect(draftOf(drafts, 'thread:2')).toBe('');
	});

	it('does not change the map it was given', () => {
		const drafts = putDraft({}, 'manager', 'hello', 1);
		putDraft(drafts, 'manager', '', 2);
		putDraft(drafts, 'thread:a', 'x', 3);
		expect(drafts).toEqual({ manager: { text: 'hello', at: 1 } });
	});
});
