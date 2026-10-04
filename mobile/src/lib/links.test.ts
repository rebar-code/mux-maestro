import { describe, expect, it } from 'vitest';
import { linkLabel, parseThreadLink, threadForLink } from './links';
import { renderMarkdown } from './markdown';
import type { Thread } from './types';

function thread(change: Partial<Thread>): Thread {
	return {
		id: 'localhost:12',
		host: 'localhost',
		session: 'acme-app',
		window: 1,
		name: 'checkout-fix',
		pane: '%12',
		status: 'idle',
		agent: null,
		...change
	} as Thread;
}

const threads = [
	thread({ id: 'localhost:12', pane: '%12', agent: '3f2c9a1e-0000-4000-8000-a0b1c2d3e4f5' }),
	thread({ id: 'localhost:13', pane: '%13', status: 'busy' }),
	thread({ id: 'localhost:296', pane: '%296', window: 2, name: 'migration', status: 'waiting' }),
	thread({ id: 'localhost:20', pane: '%20', session: 'billing', window: 0 }),
	thread({ id: 'devbox:3', pane: '%3', host: 'devbox', session: 'billing', window: 0 })
];

describe('parseThreadLink', () => {
	it('reads the link `mux link --target` prints', () => {
		// The pane id is `%296`: its percent sign is escaped in the link.
		expect(parseThreadLink('muxmaestro://open?session=acme-app&window=2&pane=%25296')).toEqual({
			kind: 'open',
			host: 'localhost',
			session: 'acme-app',
			window: 2,
			pane: '%296'
		});
	});

	it('reads a session alone, an escaped name and another host', () => {
		expect(parseThreadLink('muxmaestro://open?session=a%20%26%20b&host=devbox')).toEqual({
			kind: 'open',
			host: 'devbox',
			session: 'a & b',
			window: null,
			pane: null
		});
	});

	it('reads the link `mux link SESSION_ID` prints', () => {
		expect(parseThreadLink('muxmaestro://thread/3f2c9a1e-0000-4000-8000-a0b1c2d3e4f5')).toEqual({
			kind: 'agent',
			id: '3f2c9a1e-0000-4000-8000-a0b1c2d3e4f5'
		});
	});

	it('refuses what is not a link to a session', () => {
		for (const href of [
			'',
			'https://example.com/open?session=acme-app',
			'muxmaestro://open',
			'muxmaestro://open?window=2',
			'muxmaestro://open?session=',
			'muxmaestro://open?session=acme-app&window=two',
			'muxmaestro://open/extra?session=acme-app',
			'muxmaestro://close?session=acme-app',
			'muxmaestro://thread/',
			'muxmaestro://thread/a/b',
			'muxmaestro://thread/a_b',
			'muxmaestro://thread/abc?x=1'
		]) {
			expect(parseThreadLink(href), href).toBeNull();
		}
	});
});

describe('threadForLink', () => {
	const open = (href: string): string | undefined => {
		const link = parseThreadLink(href);
		return link ? threadForLink(link, threads)?.id : undefined;
	};

	it('opens the pane the link names', () => {
		expect(open('muxmaestro://open?session=acme-app&window=2&pane=%25296')).toBe('localhost:296');
		expect(open('muxmaestro://open?session=acme-app&pane=%2513')).toBe('localhost:13');
	});

	it('opens the first thread of a window, and of a session the one that waits', () => {
		expect(open('muxmaestro://open?session=acme-app&window=1')).toBe('localhost:12');
		expect(open('muxmaestro://open?session=acme-app')).toBe('localhost:296');
		expect(open('muxmaestro://open?session=billing')).toBe('localhost:20');
	});

	it('stays on the host the link names', () => {
		expect(open('muxmaestro://open?session=billing&host=devbox')).toBe('devbox:3');
		expect(open('muxmaestro://open?session=acme-app&host=devbox')).toBeUndefined();
	});

	it('opens the pane that runs a conversation, whatever the case of its id', () => {
		expect(open('muxmaestro://thread/3F2C9A1E-0000-4000-8000-A0B1C2D3E4F5')).toBe('localhost:12');
		expect(open('muxmaestro://thread/00000000-0000-4000-8000-000000000000')).toBeUndefined();
	});

	it('opens nothing for a session that is gone', () => {
		expect(open('muxmaestro://open?session=reports')).toBeUndefined();
		expect(open('muxmaestro://open?session=acme-app&window=9')).toBeUndefined();
	});
});

describe('linkLabel', () => {
	it('shows the session, not the address', () => {
		const label = (href: string): string => linkLabel(parseThreadLink(href)!);
		expect(label('muxmaestro://open?session=acme-app&window=2&pane=%25296')).toBe('acme-app:2');
		expect(label('muxmaestro://open?session=billing&host=devbox')).toBe('devbox/billing');
		expect(label('muxmaestro://thread/3f2c9a1e-0000-4000-8000-a0b1c2d3e4f5')).toBe(
			'thread 3f2c9a1e'
		);
	});
});

describe('a session link in a message', () => {
	const LINK = 'muxmaestro://open?session=acme-app&window=2&pane=%25296';
	/** The link as an attribute holds it: the page reads it back unescaped. */
	const ATTR = `data-thread-link="${LINK.replaceAll('&', '&amp;')}"`;

	it('is a link the app opens itself: no href, so the page never leaves', () => {
		const html = renderMarkdown(`Look at ${LINK} now.`);
		expect(html).toContain(ATTR);
		expect(html).toContain('role="link"');
		expect(html).not.toContain('href=');
		// A bare link shows the session it names, and the full stop is not part of it.
		expect(html).toContain('>acme-app:2</a> now.');
		expect(renderMarkdown(`Open ${LINK}.`)).toContain('>acme-app:2</a>.');
	});

	it('keeps the words of a link that has its own', () => {
		const html = renderMarkdown(`[the migration](${LINK})`);
		expect(html).toContain(ATTR);
		expect(html).toContain('>the migration</a>');
	});

	it('leaves a link that names no session as text', () => {
		const html = renderMarkdown('[x](muxmaestro://close?session=acme-app)');
		expect(html).not.toContain('data-thread-link');
		expect(html).not.toContain('href=');
	});

	it('still refuses the schemes it refused', () => {
		expect(renderMarkdown('[x](javascript:alert(1))')).not.toContain('<a');
	});
});
