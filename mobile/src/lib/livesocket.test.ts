import { describe, expect, it } from 'vitest';
import { afterClose, isFinal, MAX_TRIES, retryDelay, serverMessage } from './livesocket';

describe('retryDelay', () => {
	it('doubles to a cap', () => {
		expect([0, 1, 2, 3, 4, 5, 9].map(retryDelay)).toEqual([
			500, 1000, 2000, 4000, 8000, 8000, 8000
		]);
	});
});

describe('afterClose', () => {
	it('tries again after a lost connection', () => {
		expect(afterClose(1006, 0)).toEqual({ retry: 500 });
		expect(afterClose(1013, 2)).toEqual({ retry: 2000 });
		expect(afterClose(4410, 1)).toEqual({ retry: 1000 });
	});

	it('stops when another try would end the same way', () => {
		for (const code of [4401, 4403, 4404, 4408, 4409, 4503]) {
			expect(isFinal(code)).toBe(true);
			expect(afterClose(code, 0)).toEqual({ stop: true });
		}
	});

	it('stops after too many tries in a row', () => {
		expect(afterClose(1006, MAX_TRIES - 1)).toEqual({ retry: 8000 });
		expect(afterClose(1006, MAX_TRIES)).toEqual({ stop: true });
	});
});

describe('serverMessage', () => {
	it('reads the two messages the Mac sends', () => {
		expect(serverMessage('{"type":"ready","cols":120,"rows":39}')).toEqual({
			type: 'ready',
			cols: 120,
			rows: 39
		});
		expect(serverMessage('{"type":"size","cols":80,"rows":24}')?.type).toBe('size');
	});

	it('takes nothing else', () => {
		for (const raw of [
			'',
			'not json',
			'null',
			'[]',
			'{"type":"html","cols":1,"rows":1}',
			'{"type":"ready","cols":"80","rows":24}',
			'{"type":"ready","cols":0,"rows":24}',
			'{"type":"ready","cols":80,"rows":100000}',
			'{"type":"ready","cols":80.5,"rows":24}'
		]) {
			expect(serverMessage(raw), raw).toBeNull();
		}
	});
});
