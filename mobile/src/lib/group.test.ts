import { describe, expect, it } from 'vitest';
import { age, hostStatLabels, shortCwd } from './format';
import { counts, sections } from './group';
import type { Host, Thread } from './types';

function thread(over: Partial<Thread>): Thread {
	return {
		id: 'localhost:1',
		host: 'localhost',
		hostColor: '#3291ff',
		local: true,
		session: 'acme-app',
		window: 1,
		name: 'main',
		pane: '%1',
		panes: 1,
		command: 'claude',
		cwd: '/Users/me/code/acme-app',
		status: 'idle',
		since: null,
		idleStage: 'awake',
		lastPrompt: null,
		lastActivityAt: null,
		sessionActivity: 100,
		chat: true,
		...over
	};
}

const threads = [
	thread({ id: 'localhost:1', session: 'acme-app', lastPrompt: { text: 'a', at: 500 } }),
	thread({ id: 'localhost:2', session: 'acme-app', window: 2, lastPrompt: { text: 'b', at: 900 } }),
	thread({
		id: 'localhost:3',
		session: 'docs-site',
		cwd: '/Users/me/code/docs-site',
		lastActivityAt: 950
	}),
	thread({
		id: 'devbox:4',
		host: 'devbox',
		hostColor: '#f5a623',
		local: false,
		session: 'billing',
		cwd: '/srv/billing',
		status: 'waiting',
		sessionActivity: 700,
		chat: false
	})
];

describe('sections', () => {
	it('orders sessions and their windows by the newest input', () => {
		const [only] = sections(threads, 'recent');
		expect(only.title).toBeNull();
		expect(only.sessions.map((s) => s.name)).toEqual(['docs-site', 'acme-app', 'billing']);
		expect(only.sessions[1].threads.map((t) => t.id)).toEqual(['localhost:2', 'localhost:1']);
	});

	it('groups by host, local first, sessions by name', () => {
		const out = sections(threads, 'host');
		expect(out.map((s) => s.title)).toEqual(['localhost', 'devbox']);
		expect(out[0].sessions.map((s) => s.name)).toEqual(['acme-app', 'docs-site']);
	});

	it('groups by directory with the home folder shortened', () => {
		const out = sections(threads, 'directory');
		expect(out.map((s) => s.title)).toEqual([
			'~/code/acme-app',
			'/srv/billing',
			'~/code/docs-site'
		]);
	});
});

describe('counts', () => {
	it('counts waiting, busy and sleeping threads', () => {
		expect(
			counts([...threads, thread({ status: 'busy' }), thread({ idleStage: 'dozing' })])
		).toEqual({ waiting: 1, busy: 1, dozing: 1 });
	});
});

describe('format', () => {
	it('writes ages in the largest whole unit', () => {
		expect(age(60, 100)).toBe('40s');
		expect(age(0, 120)).toBe('2m');
		expect(age(0, 3 * 3600)).toBe('3h');
		expect(age(0, 2 * 86_400)).toBe('2d');
		expect(age(null, 100)).toBe('');
	});

	it('shortens only a home folder', () => {
		expect(shortCwd('/Users/me/code/acme-app')).toBe('~/code/acme-app');
		expect(shortCwd('/home/me')).toBe('~');
		expect(shortCwd('/srv/app')).toBe('/srv/app');
	});

	it('shows a dash for a number the host has not sent', () => {
		const host: Host = {
			name: 'devbox',
			color: '#f5a623',
			local: false,
			reachability: 'reachable',
			threads: 0,
			stats: null
		};
		expect(hostStatLabels(host)).toEqual(['CPU —', 'load —', 'RAM —', 'disk —']);
		const gb = 1024 ** 3;
		expect(
			hostStatLabels({
				...host,
				stats: {
					cpuPercent: 12.4,
					load1: 0.64,
					cores: 8,
					memUsedBytes: 9 * gb,
					memTotalBytes: 64 * gb,
					diskFreeBytes: 1434 * gb,
					diskTotalBytes: null,
					uptimeSeconds: null
				}
			})
		).toEqual(['CPU 12%', 'load 0.08/core', '9 / 64 GB', '1.4 TB free']);
	});
});
