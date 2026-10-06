import { describe, expect, it } from 'vitest';
import type { VoiceEnd } from '../types';
import { endVerdict, errorVerdict, newTake, takeLength } from './takes';

const end = (outcome: VoiceEnd['outcome']): VoiceEnd => ({ outcome, reply: '', message: null });

describe('what a send came to', () => {
	it('lets a take go only when its text is in the chat', () => {
		// The Mac said so, whatever came after: a reply that timed out was still sent.
		expect(endVerdict(end('timeout'), true)).toBe('sent');
		expect(endVerdict(end('unreachable'), true)).toBe('sent');
		expect(endVerdict(end('done'), false)).toBe('sent');
		expect(endVerdict(end('permission'), false)).toBe('sent');
	});

	it('keeps a take that never reached the chat', () => {
		// `timeout` without `sent` is also what a stream that died reads as.
		for (const outcome of ['failed', 'refused', 'unreachable', 'timeout'] as const) {
			expect(endVerdict(end(outcome), false)).toBe('keep');
		}
	});

	it('drops a take with no words in it', () => {
		expect(endVerdict(end('empty'), false)).toBe('drop');
	});

	it('keeps a take whose request failed, unless the audio can never be used', () => {
		expect(errorVerdict(new TypeError('Failed to fetch'))).toBe('keep');
		expect(errorVerdict({ status: 503, code: 'models' })).toBe('keep');
		expect(errorVerdict({ status: 409, code: 'busy' })).toBe('keep');
		expect(errorVerdict({ status: 409, code: 'sending' })).toBe('keep');
		expect(errorVerdict({ status: 401, code: null })).toBe('keep');
		expect(errorVerdict({ status: 502, code: null })).toBe('keep');
		// Words that were refused are no reason to drop the audio.
		expect(errorVerdict({ status: 400, code: 'bad_request' })).toBe('keep');
		for (const code of ['bad_audio', 'too_short', 'too_long']) {
			expect(errorVerdict({ status: 400, code })).toBe('drop');
		}
	});
});

describe('a kept take', () => {
	it('has an id of its own and no words yet', () => {
		const wav = new ArrayBuffer(44);
		const one = newTake('manager', wav, 2, 1000);
		const two = newTake('manager', wav, 2, 1000);
		expect(one).toMatchObject({ target: 'manager', at: 1000, seconds: 2, text: null });
		expect(one.id).toMatch(/^[0-9a-f-]{36}$/);
		expect(one.id).not.toBe(two.id);
	});

	it('shows its length as m:ss', () => {
		expect(takeLength(0.4)).toBe('0:01');
		expect(takeLength(7.2)).toBe('0:07');
		expect(takeLength(75)).toBe('1:15');
	});
});
