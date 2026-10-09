import { describe, expect, it } from 'vitest';
import { modelReady, modelRefusal } from './model';
import type { Thread } from './types';

const thread = (over: Partial<Thread>): Thread =>
	({ chat: true, status: 'idle', ...over }) as Thread;

describe('modelReady', () => {
	it('is an agent that is not in a turn or on a prompt', () => {
		expect(modelReady(thread({}))).toBe(true);
		// A remote pane's status may be unknown: the Mac reads its screen.
		expect(modelReady(thread({ status: 'unknown' }))).toBe(true);
		expect(modelReady(thread({ status: 'busy' }))).toBe(false);
		expect(modelReady(thread({ status: 'waiting' }))).toBe(false);
	});

	it('is not a pane without an agent, or a thread that is gone', () => {
		expect(modelReady(thread({ chat: false }))).toBe(false);
		expect(modelReady(undefined)).toBe(false);
	});
});

describe('modelRefusal', () => {
	it('says what the Mac said', () => {
		expect(modelRefusal('busy', 'Thread is busy')).toBe('Thread is busy');
	});

	it('names a refusal that came without words', () => {
		expect(modelRefusal('not_found', null)).toBe('No longer there');
		expect(modelRefusal('disabled', null)).toBe('Switched off on the Mac');
		expect(modelRefusal(null, null)).toBe('Failed');
	});
});
