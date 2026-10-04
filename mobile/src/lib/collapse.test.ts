import { describe, expect, it } from 'vitest';
import {
	collapsed,
	expanded,
	isCollapsed,
	parseCollapsed,
	pruned,
	serializeCollapsed,
	sessionDomId,
	sessionKey,
	SUMMARY_LABEL,
	summaryStatus
} from './collapse';
import { dotClass } from './format';

type Row = {
	status: 'waiting' | 'busy' | 'idle' | 'unknown';
	idleStage: 'awake' | 'yawning' | 'dozing';
};
const t = (status: Row['status'], idleStage: Row['idleStage'] = 'awake'): Row => ({
	status,
	idleStage
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
		expect(summaryStatus([t('idle', 'dozing')])).toBe('idle');
		expect(summaryStatus([t('unknown')])).toBe('idle');
		expect(summaryStatus([])).toBe('idle');
	});

	it('matches the row dots: a sleeping thread is grey whatever its status says', () => {
		const rows = [t('busy', 'dozing'), t('waiting', 'dozing'), t('idle')];
		// Every row's dot is grey, so the summary is too.
		expect(rows.map(dotClass)).toEqual(['idle', 'idle', 'idle']);
		expect(summaryStatus(rows)).toBe('idle');
		// One awake running row is green, and so is the summary.
		expect(summaryStatus([...rows, t('busy', 'yawning')])).toBe('busy');
	});

	it('has a spoken label for each status', () => {
		expect(SUMMARY_LABEL).toEqual({ waiting: 'needs you', busy: 'running', idle: 'idle' });
	});
});

describe('sessionDomId', () => {
	it('keeps plain names readable', () => {
		expect(sessionDomId('localhost/acme-app')).toBe('s-localhost.2facme-app');
	});

	it('never holds a space or a quote, whatever the session is called', () => {
		for (const key of [
			'devbox/my app',
			'devbox/a"b',
			"devbox/it's",
			'devbox/naïve ✦',
			'a/b c\td'
		]) {
			expect(sessionDomId(key)).toMatch(/^s-[A-Za-z0-9_.-]+$/);
		}
	});

	it('gives different sessions different ids', () => {
		const keys = [
			'devbox/my app',
			'devbox/my-app',
			'devbox/my_app',
			'devbox/my.app',
			'devbox/myapp'
		];
		expect(new Set(keys.map(sessionDomId)).size).toBe(keys.length);
	});
});

describe('pruned', () => {
	const threads = [
		{ host: 'localhost', session: 'acme-app' },
		{ host: 'devbox', session: 'billing' }
	];

	it('drops sessions that no longer exist', () => {
		const keys = new Set(['localhost/acme-app', 'localhost/gone', 'buildbox/old']);
		expect([...pruned(keys, threads)]).toEqual(['localhost/acme-app']);
	});

	it('returns the same set when every key is live', () => {
		const keys = new Set(['localhost/acme-app', 'devbox/billing']);
		expect(pruned(keys, threads)).toBe(keys);
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
