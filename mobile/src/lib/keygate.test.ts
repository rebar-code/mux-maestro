import { describe, expect, it } from 'vitest';
import { keygateLink } from './keygate';

const ORIGIN = 'https://devbox.example.ts.net';

describe('keygateLink', () => {
	it('links to the request on keygate’s origin', () => {
		expect(keygateLink({ id: 'ab12', origin: ORIGIN })).toBe(`${ORIGIN}/?id=ab12`);
		expect(keygateLink({ id: 'f'.repeat(64), origin: `${ORIGIN}:8443` })).toBe(
			`${ORIGIN}:8443/?id=${'f'.repeat(64)}`
		);
	});

	it('takes only a hex id', () => {
		for (const id of [
			'',
			'AB12',
			'ab-1',
			'g',
			'ab12&x=1',
			'ab12#x',
			'ab12\n',
			'a'.repeat(65),
			12
		]) {
			expect(keygateLink({ id, origin: ORIGIN })).toBeNull();
		}
	});

	it('takes only a bare https origin', () => {
		for (const origin of [
			'http://devbox.example.ts.net',
			'javascript:alert(1)',
			'data:text/html,x',
			'https://user:pw@devbox.example.ts.net',
			`${ORIGIN}/approve`,
			`${ORIGIN}/`,
			`${ORIGIN}?id=1`,
			`${ORIGIN}#x`,
			'devbox.example.ts.net',
			'',
			null
		]) {
			expect(keygateLink({ id: 'ab12', origin })).toBeNull();
		}
	});

	it('is null for a row without the field', () => {
		expect(keygateLink(undefined)).toBeNull();
		expect(keygateLink(null)).toBeNull();
		expect(keygateLink('https://devbox.example.ts.net/?id=ab12')).toBeNull();
	});
});
