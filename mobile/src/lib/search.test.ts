import { describe, expect, it } from 'vitest';
import { searchAll } from './search';
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

const host = (name: string, local: boolean, threads: number): Host => ({
	name,
	color: '#3291ff',
	local,
	reachability: 'reachable',
	threads,
	stats: null
});

const threads = [
	thread({ id: 'localhost:1', name: 'checkout-fix', sessionActivity: 100 }),
	thread({ id: 'localhost:2', name: 'dark-mode', window: 2, sessionActivity: 300 }),
	thread({
		id: 'devbox:1',
		host: 'devbox',
		local: false,
		session: 'billing',
		name: 'fix-proration',
		cwd: '/home/me/billing',
		command: 'codex',
		sessionActivity: 900
	}),
	thread({
		id: 'devbox:2',
		host: 'devbox',
		local: false,
		session: 'infra',
		name: 'deploy',
		cwd: '/home/me/infra',
		command: 'zsh',
		sessionActivity: 50
	})
];
const hosts = [host('localhost', true, 2), host('devbox', false, 2)];

const ids = (query: string): string[] => searchAll(query, threads, hosts).threads.map((t) => t.id);

describe('searchAll', () => {
	it('finds nothing for an empty query', () => {
		for (const query of ['', '   ']) {
			expect(searchAll(query, threads, hosts)).toEqual({ hosts: [], sessions: [], threads: [] });
		}
	});

	it('finds a window by its name, whatever the case', () => {
		expect(ids('CHECKOUT')).toEqual(['localhost:1']);
	});

	it('finds a window by its session, host, command and directory', () => {
		expect(ids('billing')).toEqual(['devbox:1']);
		expect(ids('codex')).toEqual(['devbox:1']);
		expect(ids('code/acme')).toEqual(['localhost:2', 'localhost:1']);
		expect(ids('devbox')).toEqual(['devbox:1', 'devbox:2']);
	});

	it('needs every word of the query', () => {
		expect(ids('devbox deploy')).toEqual(['devbox:2']);
		expect(ids('devbox checkout')).toEqual([]);
	});

	it('puts a name that starts with the query before a newer one that only holds it', () => {
		// `fix-proration` is newer; `checkout-fix` only has the word inside.
		expect(ids('fix')).toEqual(['devbox:1', 'localhost:1']);
		expect(ids('d')).toEqual(['localhost:2', 'devbox:2', 'devbox:1', 'localhost:1']);
	});

	it('finds sessions by name and host, the newest first', () => {
		const found = (query: string): string[] =>
			searchAll(query, threads, hosts).sessions.map((session) => session.key);
		expect(found('acme')).toEqual(['localhost/acme-app']);
		expect(found('devbox')).toEqual(['devbox/billing', 'devbox/infra']);
	});

	it('finds hosts by name, and this Mac by the word local', () => {
		const found = (query: string): string[] =>
			searchAll(query, threads, hosts).hosts.map((h) => h.name);
		expect(found('dev')).toEqual(['devbox']);
		expect(found('local')).toEqual(['localhost']);
		expect(found('checkout')).toEqual([]);
	});

	it('finds this Mac by the word local when it has another name', () => {
		const named = [host('studio', true, 0), host('devbox', false, 2)];
		expect(searchAll('local', [], named).hosts.map((h) => h.name)).toEqual(['studio']);
	});
});
