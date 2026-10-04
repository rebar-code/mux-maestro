import { describe, expect, it } from 'vitest';
import {
	collapsed,
	expanded,
	isCollapsed,
	parseCollapsed,
	serializeCollapsed,
	sessionKey,
	summaryStatus
} from './collapse';

const t = (status: 'waiting' | 'busy' | 'idle' | 'unknown'): { status: typeof status } => ({
	status
});

describe('summaryStatus', () => {
	it('needs-you wins over everything', () => {
		expect(summaryStatus([t('idle'), t('busy'), t('waiting'), t('unknown')])).toBe('waiting');
		expect(summaryStatus([t('waiting')])).toBe('waiting');
	});

	it('running wins over idle', () => {
		expect(summaryStatus([t('idle'), t('busy'), t('unknown')])).toBe('busy');
	});

	it('idle, sleeping and unknown all read as idle', () => {
		expect(summaryStatus([t('idle'), t('unknown')])).toBe('idle');
		expect(summaryStatus([t('unknown')])).toBe('idle');
		expect(summaryStatus([])).toBe('idle');
	});
});

describe('collapsed state', () => {
	it('keys a session by host and name', () => {
		expect(sessionKey('devbox', 'acme-app')).toBe('devbox/acme-app');
		expect(sessionKey('localhost', 'acme-app')).not.toBe(sessionKey('devbox', 'acme-app'));
	});

	it('collapsing adds the key without changing the original set', () => {
		const none = new Set<string>();
		const one = collapsed(none, 'devbox/acme-app');
		expect([...one]).toEqual(['devbox/acme-app']);
		expect(none.size).toBe(0);
		expect(collapsed(one, 'devbox/acme-app')).toBe(one);
	});

	it('expanding removes the key, and returns the same set when nothing changes', () => {
		const keys = new Set(['a/b', 'c/d']);
		expect([...expanded(keys, 'a/b')]).toEqual(['c/d']);
		expect(expanded(keys, 'x/y')).toBe(keys);
	});

	it('round-trips through storage', () => {
		const keys = new Set(['devbox/billing', 'localhost/acme-app']);
		expect(parseCollapsed(serializeCollapsed(keys))).toEqual(keys);
	});

	it('reads anything unusable as nothing collapsed', () => {
		for (const raw of [null, '', 'not json', '{"a":1}', '42', 'null']) {
			expect(parseCollapsed(raw).size).toBe(0);
		}
		expect([...parseCollapsed('["a/b", 7, null, "c/d"]')]).toEqual(['a/b', 'c/d']);
	});
});

describe('isCollapsed', () => {
	const keys = new Set(['localhost/acme-app']);
	const threads = [{ id: 'localhost:1' }, { id: 'localhost:4' }];

	it('follows the stored state', () => {
		expect(isCollapsed(keys, 'localhost/acme-app', threads, null)).toBe(true);
		expect(isCollapsed(keys, 'devbox/billing', [{ id: 'devbox:2' }], null)).toBe(false);
	});

	it('shows the session of the thread just opened, whatever is stored', () => {
		expect(isCollapsed(keys, 'localhost/acme-app', threads, 'localhost:4')).toBe(false);
		// A thread opened in another session does not open this one.
		expect(isCollapsed(keys, 'localhost/acme-app', threads, 'devbox:2')).toBe(true);
	});
});
