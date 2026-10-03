import { describe, expect, it } from 'vitest';
import { renderCode, renderMarkdown } from './markdown';

describe('renderMarkdown', () => {
	it('renders headings, lists and code', () => {
		const html = renderMarkdown(
			'# Plan\n\n- Add `await tax.waitFor()`\n\n```ts\nconst a = 1;\n```\n'
		);
		expect(html).toContain('<h1>Plan</h1>');
		expect(html).toContain('<code>await tax.waitFor()</code>');
		expect(html).toContain('<pre class="hljs" data-hscroll>');
		expect(html).toContain('hljs-keyword');
	});

	it('shows raw HTML as text and never as markup', () => {
		const html = renderMarkdown(
			'<script>alert(1)</script>\n\n<img src=x onerror=alert(1)>\n\nhi <b onclick="x()">there</b> <iframe src="/api/config"></iframe>'
		);
		expect(html).not.toMatch(/<script|<img|<iframe|<b /i);
		expect(html).toContain('&lt;script&gt;');
		expect(html).toContain('&lt;img src=x onerror=alert(1)&gt;');
	});

	it('drops script links and keeps web links, opened in a new tab without a referrer', () => {
		const html = renderMarkdown(
			'[a](javascript:alert(1)) [b](data:text/html,<script>1</script>) [c](vbscript:x) [d](https://example.com/x)'
		);
		expect(html).not.toMatch(/href="(javascript|data|vbscript):/i);
		expect(html).toContain(
			'<a href="https://example.com/x" target="_blank" rel="noopener noreferrer">d</a>'
		);
	});

	it('loads no image', () => {
		const html = renderMarkdown('![shot](https://example.com/pixel.png)');
		expect(html).not.toContain('<img');
	});

	it('escapes what a code block holds, with or without a language', () => {
		for (const fence of ['```html', '```', '```nosuchlanguage']) {
			const html = renderMarkdown(`${fence}\n<script>alert(1)</script>\n\`\`\`\n`);
			expect(html).not.toContain('<script>');
			expect(html).toContain('&lt;');
		}
		expect(renderMarkdown('    <script>alert(1)</script>\n')).not.toContain('<script>');
	});

	it('draws front matter as a block, not as a heading', () => {
		const html = renderMarkdown('---\ntitle: Plan\n---\n\n# Body\n');
		expect(html).not.toContain('<h2>');
		expect(html).toContain('<h1>Body</h1>');
		expect(html).toContain('<pre class="hljs" data-hscroll>');
	});
});

describe('renderCode', () => {
	it('highlights by file name and escapes the text', () => {
		const html = renderCode('const a = "<script>";', 'a.ts');
		expect(html).toContain('hljs-keyword');
		expect(html).not.toContain('<script>');
		expect(renderCode('<b>x</b>', 'notes.unknownext')).toBe('&lt;b&gt;x&lt;/b&gt;');
		expect(renderCode('all: build', 'Makefile')).toContain('hljs');
	});
});
