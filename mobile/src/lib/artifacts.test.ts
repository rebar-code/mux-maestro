import { describe, expect, it } from 'vitest';
import { fileSize, framedHtml, hasThumb, inlineArtifacts, isViewable } from './artifacts';
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
});
