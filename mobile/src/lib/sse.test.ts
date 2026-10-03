import { describe, expect, it } from 'vitest';
import { frameParser } from './sse';

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
