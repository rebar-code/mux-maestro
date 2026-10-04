import { describe, expect, it } from 'vitest';
import { isIOS, keyBytes, parsePush, pushStatus, sameKey, threadUrl, type PushEnv } from './push';

const env = (over: Partial<PushEnv>): PushEnv => ({
	ios: true,
	standalone: true,
	supported: true,
	permission: 'default',
	subscribed: false,
	...over
});

describe('pushStatus', () => {
	it('asks for the Home Screen first on iOS', () => {
		expect(pushStatus(env({ standalone: false, supported: false }))).toBe('install');
		expect(pushStatus(env({ standalone: false, permission: 'granted', subscribed: true }))).toBe(
			'install'
		);
	});

	it('says when the browser has no push', () => {
		expect(pushStatus(env({ ios: false, standalone: false, supported: false }))).toBe(
			'unsupported'
		);
		expect(pushStatus(env({ supported: false }))).toBe('unsupported');
	});

	it('says when permission was refused', () => {
		expect(pushStatus(env({ permission: 'denied', subscribed: true }))).toBe('denied');
	});

	it('is on only with a subscription and permission', () => {
		expect(pushStatus(env({}))).toBe('off');
		expect(pushStatus(env({ permission: 'granted' }))).toBe('off');
		expect(pushStatus(env({ subscribed: true }))).toBe('off');
		expect(pushStatus(env({ permission: 'granted', subscribed: true }))).toBe('on');
	});
});

describe('isIOS', () => {
	it('knows an iPhone, and an iPad that says it is a Mac', () => {
		expect(isIOS('Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)', 'iPhone', 5)).toBe(true);
		expect(isIOS('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)', 'MacIntel', 5)).toBe(true);
		expect(isIOS('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)', 'MacIntel', 0)).toBe(false);
		expect(isIOS('Mozilla/5.0 (Linux; Android 15)', 'Linux armv81', 5)).toBe(false);
	});
});

describe('keys', () => {
	it('decodes the Mac key and compares it with a subscription key', () => {
		expect([...keyBytes('BP4z_-8')]).toEqual([4, 254, 51, 255, 239]);
		expect(sameKey(keyBytes('BP4z_-8').buffer, 'BP4z_-8')).toBe(true);
		expect(sameKey(keyBytes('BP4z_-o').buffer, 'BP4z_-8')).toBe(false);
		expect(sameKey(keyBytes('BP4z').buffer, 'BP4z_-8')).toBe(false);
		expect(sameKey(null, 'BP4z_-8')).toBe(false);
	});
});

describe('parsePush', () => {
	it('reads the notification the Mac sent', () => {
		expect(
			parsePush(
				JSON.stringify({
					v: 1,
					kind: 'waiting',
					title: 'MuxMaestro',
					body: 'A thread needs you',
					tag: 'abc',
					thread: 'devbox:7'
				})
			)
		).toEqual({ title: 'MuxMaestro', body: 'A thread needs you', tag: 'abc', thread: 'devbox:7' });
	});

	it('still gives a notification for a message it cannot read', () => {
		const generic = { title: 'MuxMaestro', body: '', tag: 'muxmaestro', thread: '' };
		expect(parsePush(null)).toEqual(generic);
		expect(parsePush('not json')).toEqual(generic);
		expect(parsePush('{"title":7,"thread":null}')).toEqual(generic);
	});

	it('cuts a long text', () => {
		expect(parsePush(JSON.stringify({ body: 'a'.repeat(5000) })).body).toHaveLength(300);
	});
});

describe('threadUrl', () => {
	it('names the thread page, or the first screen', () => {
		expect(threadUrl('devbox:7')).toBe('/t/devbox%3A7');
		expect(threadUrl('')).toBe('/');
	});
});
