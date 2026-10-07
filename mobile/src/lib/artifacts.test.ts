import { describe, expect, it } from 'vitest';
import {
	fileSize,
	framedHtml,
	hasThumb,
	imageAddress,
	imageUrl,
	inlineArtifacts,
	isViewable,
	savedBlob,
	SAVED_TYPE,
	neighbour,
	swipeStep
} from './artifacts';
import type { ArtifactFile, ChatMessage } from './types';

const file = (
	name: string,
	kind: ArtifactFile['kind'],
	more: Partial<ArtifactFile> = {}
): ArtifactFile => ({
	id: name,
	name,
	dir: '/Users/me/code/acme-app',
	kind,
	mime: 'text/plain; charset=utf-8',
	size: 1200,
	at: 100,
	exists: true,
	...more
});

const chat = (rows: [ChatMessage['role'], string][]): ChatMessage[] =>
	rows.map(([role, text], n) => ({ n, role, text, ...(role === 'tool' ? { tool: 'Edit' } : {}) }));

describe('inlineArtifacts', () => {
	const plan = file('PLAN.md', 'markdown');
	const shot = file('checkout-after.png', 'image', { dir: '/tmp' });
	const spec = file('checkout.spec.ts', 'code', { dir: '/Users/me/code/acme-app/tests' });

	it('puts a file under the tool row that wrote it, by absolute or relative path', () => {
		const messages = chat([
			['user', 'write PLAN.md'],
			['tool', '/Users/me/code/acme-app/PLAN.md'],
			['tool', 'tests/checkout.spec.ts'],
			['assistant', 'Done.']
		]);
		const inline = inlineArtifacts(messages, [plan, spec]);
		expect(inline.get(1)).toEqual([plan]);
		expect(inline.get(2)).toEqual([spec]);
		expect(inline.get(0)).toBeUndefined();
	});

	it('puts a file under the reply that names it, once, at the last mention', () => {
		const messages = chat([
			['assistant', 'Saved /tmp/checkout-after.png'],
			['tool', '/Users/me/code/acme-app/PLAN.md'],
			['assistant', 'See checkout-after.png and PLAN.md.']
		]);
		const inline = inlineArtifacts(messages, [shot, plan]);
		expect(inline.get(2)).toEqual([shot, plan]);
		expect(inline.size).toBe(1);
	});

	it('does not match a longer name, a missing file or what the human typed', () => {
		const messages = chat([
			['user', 'PLAN.md'],
			['assistant', 'OLD-PLAN.md and PLAN.md.bak and my/PLAN.mdx are other files'],
			['tool', 'docs/OTHER-PLAN.md']
		]);
		expect(inlineArtifacts(messages, [plan]).size).toBe(0);
		const gone = file('PLAN.md', 'markdown', { exists: false });
		expect(inlineArtifacts(chat([['assistant', 'PLAN.md']]), [gone]).size).toBe(0);
	});
});

describe('what the viewer draws', () => {
	it('thumbnails small images only', () => {
		expect(hasThumb(file('a.png', 'image'))).toBe(true);
		expect(hasThumb(file('a.png', 'image', { size: 9_000_000 }))).toBe(false);
		expect(hasThumb(file('a.md', 'markdown'))).toBe(false);
		expect(hasThumb(file('a.png', 'image', { exists: false, size: null }))).toBe(false);
	});

	it('renders text up to a limit and leaves the rest to Share', () => {
		expect(isViewable(file('a.md', 'markdown'))).toBe(true);
		expect(isViewable(file('a.log', 'text', { size: 2_000_000 }))).toBe(false);
		expect(isViewable(file('a.pdf', 'pdf'))).toBe(false);
		expect(isViewable(file('a.bin', 'other'))).toBe(false);
		expect(isViewable(file('a.png', 'image', { size: 9_000_000 }))).toBe(true);
	});

	it('labels sizes', () => {
		expect(fileSize(620)).toBe('620 B');
		expect(fileSize(14_336)).toBe('14 KB');
		expect(fileSize(3_355_443)).toBe('3.2 MB');
		expect(fileSize(null)).toBe('');
	});
});

describe('framedHtml', () => {
	it('puts a policy that loads nothing ahead of the page', () => {
		const framed = framedHtml('<script>alert(1)</script>');
		expect(framed.startsWith('<meta http-equiv="Content-Security-Policy"')).toBe(true);
		expect(framed).toContain("default-src 'none'");
		expect(framed).not.toMatch(/script-src|connect-src|unsafe-eval/);
	});

	it('keeps the doctype first, so the page stays in standards mode', () => {
		for (const head of [
			'<!doctype html>',
			'<!DOCTYPE html>\n',
			'\n <!-- made by a tool -->\n<!doctype html>'
		]) {
			const framed = framedHtml(`${head}<html><head><title>x</title></head></html>`);
			expect(framed.startsWith(`${head}<meta http-equiv="Content-Security-Policy"`)).toBe(true);
			expect(framed.match(/Content-Security-Policy/g)).toHaveLength(1);
		}
	});

	it('sends every link to a new window, which the sandbox then refuses', () => {
		const framed = framedHtml(
			'<!doctype html><base target="_self"><a href="https://example.com">x</a>'
		);
		expect(framed.indexOf('<base target="_blank">')).toBeGreaterThan(0);
		expect(framed.indexOf('<base target="_blank">')).toBeLessThan(
			framed.indexOf('<base target="_self">')
		);
	});
});

describe('imageAddress', () => {
	it('gives a picture format a blob of that exact type', () => {
		for (const type of ['image/png', 'image/jpeg', 'image/gif', 'image/webp']) {
			expect(imageAddress(type)).toEqual({ as: 'blob', type });
		}
		expect(imageAddress('IMAGE/PNG; charset=binary')).toEqual({ as: 'blob', type: 'image/png' });
	});

	it('never gives SVG a blob: it becomes a data address with no origin', () => {
		expect(imageAddress('image/svg+xml')).toEqual({ as: 'data', type: 'image/svg+xml' });
		expect(imageAddress('image/svg+xml; charset=utf-8')).toEqual({
			as: 'data',
			type: 'image/svg+xml'
		});
	});

	it('shows nothing for a type that could be a page', () => {
		for (const type of [
			'text/html',
			'application/xhtml+xml',
			'text/xml',
			'application/xml',
			'',
			'application/pdf',
			'text/plain'
		]) {
			expect(imageAddress(type)).toBeNull();
		}
	});

	it('saves every file as plain bytes', () => {
		expect(SAVED_TYPE).toBe('application/octet-stream');
	});
});

describe('no blob address for a type that can run script', () => {
	// A `blob:` address is in the app's origin. A browser that opens one of
	// these as a page runs it there; no policy stops that. The type is the guard.
	const SCRIPTABLE = [
		'text/html',
		'TEXT/HTML; charset=utf-8',
		'application/xhtml+xml',
		'text/xml',
		'application/xml',
		'application/rss+xml',
		'image/svg+xml',
		'image/svg+xml; charset=utf-8',
		' Image/SVG+XML ',
		'application/pdf',
		'text/javascript',
		'application/octet-stream',
		'text/plain',
		'image/x-unknown',
		''
	];
	const dangerous = /html|xml|svg|pdf|script/i;

	it('imageUrl never hands such a blob to createObjectURL', async () => {
		for (const type of SCRIPTABLE) {
			const made: Blob[] = [];
			const url = await imageUrl(
				new Blob(['<svg xmlns="http://www.w3.org/2000/svg"/>'], { type }),
				(blob) => {
					made.push(blob);
					return 'blob:made';
				}
			).catch(() => null);
			expect(made, type).toEqual([]);
			if (url !== null) expect(url, type).toMatch(/^data:image\/svg\+xml;base64,/);
		}
	});

	it('imageUrl gives a picture a blob of its own exact type, whatever the parameters', async () => {
		for (const [type, exact] of [
			['image/png', 'image/png'],
			['image/jpeg; charset=binary', 'image/jpeg'],
			['IMAGE/WEBP', 'image/webp'],
			['image/gif', 'image/gif']
		]) {
			const made: Blob[] = [];
			const url = await imageUrl(new Blob(['x'], { type }), (blob) => {
				made.push(blob);
				return 'blob:made';
			});
			expect(url).toBe('blob:made');
			expect(made.map((blob) => blob.type)).toEqual([exact]);
			expect(made[0].type).not.toMatch(dangerous);
		}
	});

	it('a saved file is plain bytes, whatever it was', async () => {
		for (const type of SCRIPTABLE) {
			const saved = savedBlob(new Blob(['<script>1</script>'], { type }));
			expect(saved.type, type).toBe('application/octet-stream');
			expect(await saved.text()).toBe('<script>1</script>');
		}
	});
});

describe('a swipe up or down on an open file', () => {
	const still = { dx: 0, atTop: true, atEnd: true };

	it('steps to the next file on a swipe up and the previous on a swipe down', () => {
		expect(swipeStep({ ...still, dy: -120 })).toBe(1);
		expect(swipeStep({ ...still, dy: 120 })).toBe(-1);
	});

	it('takes a short move or a sideways one for neither', () => {
		expect(swipeStep({ ...still, dy: -40 })).toBe(0);
		expect(swipeStep({ ...still, dy: -120, dx: 110 })).toBe(0);
	});

	it('lets a file that scrolls scroll first', () => {
		expect(swipeStep({ ...still, dy: -120, atEnd: false })).toBe(0);
		expect(swipeStep({ ...still, dy: 120, atTop: false })).toBe(0);
		// From its end it goes on, and from its top it goes back.
		expect(swipeStep({ ...still, dy: -120, atTop: false })).toBe(1);
		expect(swipeStep({ ...still, dy: 120, atEnd: false })).toBe(-1);
	});

	it('finds the neighbour in the list, and none past its ends', () => {
		const files = [file('a.md', 'markdown'), file('b.ts', 'code'), file('c.png', 'image')];
		expect(neighbour(files, 'b.ts', 1)?.id).toBe('c.png');
		expect(neighbour(files, 'b.ts', -1)?.id).toBe('a.md');
		expect(neighbour(files, 'c.png', 1)).toBeNull();
		expect(neighbour(files, 'a.md', -1)).toBeNull();
		expect(neighbour(files, 'gone.txt', 1)).toBeNull();
	});
});
