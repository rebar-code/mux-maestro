import { describe, expect, it } from 'vitest';
import { tokenFrom, withoutPair } from './pairing';

const token = 'q3J5cHRvLXJhbmRvbS0zMi1ieXRlcy1iYXNlNjR1cmw';

describe('tokenFrom', () => {
	it('takes the token from a pairing link', () => {
		expect(tokenFrom(`https://devmac.example.ts.net:7433/#pair=${token}`)).toBe(token);
		expect(tokenFrom(`  #pair=${token}\n`)).toBe(token);
	});

	it('takes a bare token', () => {
		expect(tokenFrom(token)).toBe(token);
	});

	it('refuses anything else', () => {
		expect(tokenFrom('')).toBeNull();
		expect(tokenFrom('https://devmac.example.ts.net:7433/')).toBeNull();
		expect(tokenFrom('two words')).toBeNull();
		expect(tokenFrom('#pair=')).toBeNull();
	});
});

describe('withoutPair', () => {
	it('removes only the pairing part', () => {
		expect(withoutPair(`#pair=${token}`)).toBe('');
		expect(withoutPair(`#a=1&pair=${token}`)).toBe('#a=1');
		expect(withoutPair('')).toBe('');
	});
});
