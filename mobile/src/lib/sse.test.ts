import { describe, expect, it, vi } from 'vitest';
import { frameParser, readOrStall, STALLED } from './sse';

describe('frameParser', () => {
	it('reads one frame', () => {
		expect(frameParser()('event: threads\ndata: {"threads":[]}\n\n')).toEqual([
			{ event: 'threads', data: '{"threads":[]}' }
		]);
	});

	it('reads two frames from one chunk', () => {
		expect(frameParser()('event: a\ndata: 1\n\nevent: b\ndata: 2\n\n')).toEqual([
			{ event: 'a', data: '1' },
			{ event: 'b', data: '2' }
		]);
	});

	it('waits for the rest of a frame split across chunks', () => {
		const push = frameParser();
		expect(push('event: thr')).toEqual([]);
		expect(push('eads\ndata: {"a"')).toEqual([]);
		expect(push(':1}\n')).toEqual([]);
		expect(push('\nevent: hosts\n')).toEqual([{ event: 'threads', data: '{"a":1}' }]);
		expect(push('data: 2\n\n')).toEqual([{ event: 'hosts', data: '2' }]);
	});

	it('ignores comment lines and comment-only blocks', () => {
		const push = frameParser();
		expect(push(': ping\n\n')).toEqual([]);
		expect(push(': ping\nevent: a\n: note\ndata: 1\n\n')).toEqual([{ event: 'a', data: '1' }]);
	});

	it('accepts CRLF line ends and a missing space after the colon', () => {
		expect(frameParser()('event:a\r\ndata:1\r\n\r\n')).toEqual([{ event: 'a', data: '1' }]);
	});

	it('names an unnamed frame "message"', () => {
		expect(frameParser()('data: hi\n\n')).toEqual([{ event: 'message', data: 'hi' }]);
	});
});

describe('readOrStall', () => {
	it('gives the read when it arrives in time', async () => {
		expect(await readOrStall(() => Promise.resolve('chunk'), 1000)).toBe('chunk');
	});

	it('gives up on a read that never arrives, and leaves no timer behind', async () => {
		vi.useFakeTimers();
		try {
			const result = readOrStall(() => new Promise<string>(() => {}), 45_000);
			await vi.advanceTimersByTimeAsync(44_999);
			let settled = false;
			void result.then(() => (settled = true));
			await Promise.resolve();
			expect(settled).toBe(false);
			await vi.advanceTimersByTimeAsync(1);
			expect(await result).toBe(STALLED);

			await readOrStall(() => Promise.resolve('chunk'), 45_000);
			expect(vi.getTimerCount()).toBe(0);
		} finally {
			vi.useRealTimers();
		}
	});

	it('passes a failed read on', async () => {
		await expect(readOrStall(() => Promise.reject(new Error('reset')), 1000)).rejects.toThrow(
			'reset'
		);
	});
});
