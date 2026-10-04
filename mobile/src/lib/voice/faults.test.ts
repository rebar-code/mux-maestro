import { describe, expect, it } from 'vitest';
import { dropLabel, micFault, requestFault } from './faults';

const refused = (status: number, code: string | null, detail: string | null = null): unknown => ({
	status,
	code,
	detail
});

describe('fault labels', () => {
	it('names why the mic did not open', () => {
		expect(micFault(new DOMException('', 'NotAllowedError'))).toBe('Mic blocked');
		expect(micFault(new DOMException('', 'SecurityError'))).toBe('Mic blocked');
		expect(micFault(new DOMException('', 'NotFoundError'))).toBe('No microphone');
		expect(micFault(new DOMException('', 'NotReadableError'))).toBe('Mic in use');
		expect(micFault(new Error('anything else'))).toBe('Mic not available');
		// No `mediaDevices` at all: the page is not on HTTPS.
		expect(
			micFault(new TypeError("undefined is not an object (evaluating 'a.getUserMedia')"))
		).toBe('Mic not available');
	});

	it('names why the Mac did not take a request', () => {
		// The request never got an answer.
		expect(requestFault(new TypeError('Load failed'))).toBe('Mac not reachable');
		expect(requestFault(refused(401, 'unpaired'))).toBe('Not paired');
		expect(requestFault(refused(403, 'forbidden'))).toBe('Not allowed');
		expect(requestFault(refused(403, 'disabled'))).toBe('Off in MuxMaestro Settings');
		expect(requestFault(refused(503, 'models', 'Voice models not ready'))).toBe(
			'Voice models loading'
		);
		expect(requestFault(refused(413, 'too_long', 'Recording is longer than 120 seconds'))).toBe(
			'Take too long'
		);
		expect(requestFault(refused(413, null))).toBe('Take too long');
		// The Mac's own sentence, when it sent one.
		expect(requestFault(refused(409, 'waiting', 'Manager is waiting on a prompt'))).toBe(
			'Manager is waiting on a prompt'
		);
		expect(requestFault(refused(404, 'nothing', 'Nothing to replay'))).toBe('Nothing to replay');
		expect(requestFault(refused(502, null))).toBe('Mac not reachable');
		expect(requestFault(refused(500, null))).toBe('Mac error 500');
	});

	it('names why a take was not sent', () => {
		expect(dropLabel('empty')).toBe('Mic gave no sound');
		expect(dropLabel('silent')).toBe('No speech heard');
	});
});
