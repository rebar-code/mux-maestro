import { describe, expect, it } from 'vitest';
import { resolveArtifact } from './artifacts';
import { chatHits } from './find';
import {
	chatBlocks,
	chatText,
	imagePaths,
	markedBlocks,
	markHits,
	MARKDOWN_MAX,
	plainText,
	renderMarkdown
} from './markdown';
import type { ArtifactFile, ChatMessage } from './types';

const html = (text: string): string => chatBlocks(text).join('');

/** Every tag `html` opens, by name. */
const tags = (out: string): Set<string> =>
	new Set([...out.matchAll(/<([a-z][a-z0-9]*)/gi)].map((found) => found[1].toLowerCase()));

/** The tags the renderer writes. Anything else in its output is a hole. */
const WRITTEN = new Set(
	(
		'p br strong em s code pre div button span a ul ol li h1 h2 h3 h4 h5 h6 ' +
		'blockquote hr table thead tbody tr th td input mark'
	).split(' ')
);

/** Every attribute name in `html`. */
const attributes = (out: string): Set<string> => {
	const names = new Set<string>();
	for (const [tag] of out.matchAll(/<[a-z][^>]*>/gi)) {
		for (const [, name] of tag.matchAll(/\s([a-z-]+)(?:=|\s|>)/gi)) names.add(name.toLowerCase());
	}
	return names;
};

const ALLOWED_ATTRIBUTES = new Set(
	(
		'class type href target rel role tabindex style disabled checked start ' +
		'data-copy data-hscroll data-local data-rest data-file data-img data-find-current aria-label'
	).split(' ')
);

function expectInert(out: string): void {
	for (const tag of tags(out)) expect(WRITTEN, `<${tag}>`).toContain(tag);
	for (const name of attributes(out)) expect(ALLOWED_ATTRIBUTES, name).toContain(name);
	for (const [, href] of out.matchAll(/href="([^"]*)"/g)) {
		expect(href).toMatch(/^(https?:\/\/|mailto:)/i);
	}
	expect(out).not.toMatch(/<img|<script|<iframe|<object|<embed|<svg|<form|<style|<link|<meta/i);
}

describe('chat markdown', () => {
	it('renders the elements a reply uses', () => {
		const out = html(
			[
				'# Title',
				'',
				'Some **bold**, *italic* and `code`.',
				'',
				'- one',
				'  - nested',
				'- two',
				'',
				'1. first',
				'2. second',
				'',
				'> quoted',
				'',
				'---',
				'',
				'| a | b |',
				'|---|---|',
				'| 1 | 2 |',
				'',
				'```ts',
				'const a = 1;',
				'```',
				''
			].join('\n')
		);
		expect(out).toContain('<h1>Title</h1>');
		expect(out).toContain('<strong>bold</strong>');
		expect(out).toContain('<em>italic</em>');
		expect(out).toContain('<code>code</code>');
		expect(out).toMatch(/<ul>\s*<li>one\s*<ul>\s*<li>nested<\/li>/);
		expect(out).toMatch(/<ol>\s*<li>first<\/li>/);
		expect(out).toContain('<blockquote>');
		expect(out).toContain('<hr>');
		expect(out).toContain('<div class="tablebox" data-hscroll><table>');
		expect(out).toContain('<pre class="hljs" data-hscroll>');
		expect(out).toContain('hljs-keyword');
		expect(out).toContain('data-copy aria-label="Copy"');
		expectInert(out);
	});

	it('keeps the line breaks of a paragraph', () => {
		expect(html('one\ntwo')).toBe('<p>one<br>\ntwo</p>\n');
	});

	it('draws task lists as boxes that cannot be changed', () => {
		const out = html('- [ ] todo\n- [x] done\n- [link] not a task');
		expect(out).toContain('<li class="task"><input type="checkbox" disabled> todo</li>');
		expect(out).toContain('<li class="task"><input type="checkbox" disabled checked> done</li>');
		expect(out).toContain('<li>[link] not a task</li>');
	});

	it('gives one string for each top-level block, and the same ones for the same text', () => {
		const first = chatBlocks('# A\n\ntext\n\n- x\n- y\n');
		expect(first).toHaveLength(3);
		expect(chatBlocks('# A\n\ntext\n\n- x\n- y\n')).toBe(first);
		// A message that grows keeps the blocks before its end.
		const grown = chatBlocks('# A\n\ntext\n\n- x\n- y\n\nmore');
		expect(grown.slice(0, 3)).toEqual(first);
	});

	it('renders a message that is still arriving', () => {
		expect(html('Run:\n\n```sh\nmake te')).toContain('<code>make te');
		expect(html('```')).toContain('<pre');
		expect(html('- one\n- ')).toContain('<li>one</li>');
		expect(html('a **bold')).toBe('<p>a **bold</p>\n');
		expect(html('[link](https://exa')).toContain('<p>[link](');
		expect(html('| a | b |\n|--')).toContain('| a | b |');
		for (let end = 0; end <= 60; end += 1) {
			expectInert(
				html('# T\n\n- a `b`\n\n```js\nlet x = "<i>";\n```\n\n[l](http://e.com)'.slice(0, end))
			);
		}
	});
});

describe('links', () => {
	it('opens a web link in a new tab with no opener and no referrer', () => {
		expect(html('[d](https://example.com/x)')).toContain(
			'<a href="https://example.com/x" target="_blank" rel="noopener noreferrer">d</a>'
		);
		expect(html('mail [me](mailto:me@example.com)')).toContain('href="mailto:me@example.com"');
		expect(html('see https://example.com/y now')).toContain('href="https://example.com/y"');
	});

	it('does not guess that a file name is a web address', () => {
		for (const text of ['open notes.md', 'main.rs and app.py', 'www.example.com', 'me@example.com'])
			expect(html(text)).not.toContain('<a');
		expect(html('ftp://example.com/x')).not.toContain('<a');
		expect(html('//example.com/x')).not.toContain('<a');
	});

	it('gives a path no address: the view decides what a tap does', () => {
		const out = html('[plan](docs/plan.md) [abs](/Users/me/code/a.ts) [up](./b%20c.md#top)');
		expect(out).not.toContain('href');
		expect(out).toContain('data-file="docs/plan.md"');
		expect(out).toContain('data-file="/Users/me/code/a.ts"');
		expect(out).toContain('data-file="b c.md"');
		expect(html('[x](//example.com/a)')).not.toContain('href');
	});

	it('gives a local address no address either: it goes through Servers', () => {
		for (const [text, port, rest] of [
			['[app](http://localhost:5173/cart?x=1#top)', '5173', '/cart?x=1#top'],
			['http://127.0.0.1:8080', '8080', '/'],
			['[a](http://0.0.0.0:3000/)', '3000', '/'],
			['[a](http://[::1]:9000/z)', '9000', '/z'],
			['[a](https://app.localhost/)', '443', '/'],
			['[a](http://LOCALHOST/)', '80', '/']
		]) {
			const out = html(text);
			expect(out, text).not.toContain('href');
			expect(out, text).toContain(`data-local="${port}" data-rest="${rest}"`);
		}
		expect(html('[a](https://localhost.example.com/)')).toContain('href=');
	});
});

describe('images', () => {
	it('loads none: an image is its alt text in a chip', () => {
		const out = html('![a shot](https://example.com/pixel.png) ![home](shots/home.png) ![](x.png)');
		expect(out).not.toMatch(/<img|src=/);
		expect(out).toContain('<span class="mdimg">a shot</span>');
		expect(out).toContain('<span class="mdimg" data-img="shots/home.png">home</span>');
		expect(out).toContain('<span class="mdimg" data-img="x.png">x.png</span>');
		expect(html('![x](data:image/png;base64,AAAA)')).not.toContain('mdimg');
	});

	it('names the paths of a message, for the view to match with the thread files', () => {
		expect(imagePaths('![a](shots/a&b.png) and ![b](https://example.com/b.png)')).toEqual([
			'shots/a&b.png'
		]);
	});

	it('resolves a path to a file of the thread, or to nothing', () => {
		const file = (name: string, dir: string, exists = true): ArtifactFile => ({
			id: `${dir}/${name}`,
			name,
			dir,
			kind: 'image',
			mime: 'image/png',
			size: 10,
			at: 1,
			exists
		});
		const files = [
			file('home.png', '/Users/me/code/acme-app/shots'),
			file('home.png', '/Users/me/code/acme-app/old'),
			file('gone.png', '/Users/me/code/acme-app', false)
		];
		expect(resolveArtifact('shots/home.png', files)).toBe(files[0]);
		expect(resolveArtifact('./old/home.png', files)).toBe(files[1]);
		expect(resolveArtifact('/Users/me/code/acme-app/old/home.png', files)).toBe(files[1]);
		expect(resolveArtifact('home.png', files)).toBe(files[0]);
		expect(resolveArtifact('gone.png', files)).toBeNull();
		expect(resolveArtifact('me.png', files)).toBeNull();
		expect(resolveArtifact('', files)).toBeNull();
	});
});

describe('find in rendered text', () => {
	it('looks in what a message shows, not in its markdown', () => {
		expect(chatText('a **bold** `x<y` [l](https://e.com)')).toBe('a bold x<y l\n');
		expect(plainText('<p>a &amp;amp; &lt;b&gt; &quot;c&quot;</p>')).toBe('a &amp; <b> "c"');
		const messages: ChatMessage[] = [
			{ n: 0, role: 'assistant', text: 'the **bold** move' },
			{ n: 1, role: 'user', text: 'the **bold** move' }
		];
		const shown = (m: ChatMessage): string => (m.role === 'assistant' ? chatText(m.text) : m.text);
		expect(chatHits(messages, 'bold move', shown).count).toBe(1);
		expect(chatHits(messages, '**bold**', shown).byRow.has(1)).toBe(true);
	});

	it('marks a hit, also across tags and entities, and keeps the tags nested', () => {
		const text = 'the **bold** move & `a<b`\n\nsecond bold';
		const hits = chatHits([{ n: 0, role: 'assistant', text }], 'bold', () => chatText(text));
		const out = markedBlocks(text, hits.byRow.get(0) ?? [], 1);
		expect(out[0]).toContain('<strong><mark>bold</mark></strong>');
		expect(out[1]).toBe('<p>second <mark class="cur" data-find-current>bold</mark></p>\n');

		const across = markHits(
			'<p>a <strong>bo</strong>ld &amp; x</p>',
			[{ index: 0, range: [2, 8] }],
			0,
			0
		);
		expect(across).toBe(
			'<p>a <strong><mark class="cur" data-find-current>bo</mark></strong>' +
				'<mark class="cur">ld </mark><mark class="cur">&amp;</mark> x</p>'
		);
		expect(plainText(across)).toBe('a bold & x');
	});

	it('marks inside highlighted code', () => {
		const text = '```ts\nconst total = 1;\n```';
		const plain = chatText(text);
		const at = plain.indexOf('const total');
		const [out] = markedBlocks(text, [{ index: 0, range: [at, at + 11] }], 0);
		expect(plainText(out)).toBe(plain);
		expect(out).toContain('<mark class="cur" data-find-current>const</mark>');
		expectInert(out);
	});
});

describe('hostile input', () => {
	const HOSTILE = [
		'<script>window.__ran = 1</script>',
		'<img src=x onerror="window.__ran=1">',
		'<svg/onload=alert(1)>',
		'<iframe src="javascript:alert(1)"></iframe>',
		'<a href="javascript:alert(1)" onclick="alert(1)">x</a>',
		'hi <b onmouseover=alert(1)>there</b>',
		'</p></div><script>alert(1)</script>',
		'<!-- --><script>alert(1)</script>',
		'<style>*{display:none}</style><link rel=stylesheet href=//example.com/x.css>',
		'<meta http-equiv=refresh content="0;url=https://example.com">',
		'<form action=https://example.com><input name=q></form>',
		'[a](javascript:alert(1))',
		'[a](JaVaScRiPt:alert(1))',
		'[a]( javascript:alert(1))',
		'[a](java\tscript:alert(1))',
		'[a](java\nscript:alert(1))',
		'[a](&#106;avascript:alert(1))',
		'[a](&#x6A;avascript&colon;alert(1))',
		'[a](javascript&#58;alert(1))',
		'[a](\u0001javascript:alert(1))',
		'[a](java​script:alert(1))',
		'[a](<javascript:alert(1)>)',
		'[a](javascript:alert(1) "title")',
		'[a][r]\n\n[r]: javascript:alert(1)',
		'<javascript:alert(1)>',
		'[a](vbscript:msgbox(1))',
		'[a](data:text/html,<script>alert(1)</script>)',
		'[a](data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==)',
		'[a](file:///etc/passwd)',
		'[a](blob:https://example.com/1234)',
		'[a](ftp://example.com/x)',
		'[a](https://example.com/"onclick="alert(1))',
		'[a](https://example.com/ "t\\" onclick=\\"alert(1)")',
		'![x](javascript:alert(1))',
		'![x](data:image/svg+xml,<svg onload=alert(1)>)',
		'![x" onerror="alert(1)](https://example.com/p.png)',
		'![x](https://example.com/p.png "t\\" onerror=\\"alert(1)")',
		'![x](x.png"onerror="alert(1))',
		'```"><script>alert(1)</script>\ncode\n```',
		'```js" onload="alert(1)\ncode\n```',
		'```html\n</code></pre><script>alert(1)</script>\n```',
		'````\n```\n<script>alert(1)</script>\n```\n````',
		'```\n```\n```\n<script>alert(1)</script>',
		'~~~\n<script>alert(1)</script>',
		'`<script>alert(1)</script>`',
		'| a |\n|---|\n| <script>alert(1)</script> |',
		'- [x] <input onfocus=alert(1) autofocus>',
		'https://example.com/<script>alert(1)</script>',
		'safe‮gnp.exe ⁦x⁩'
	];

	it('writes only its own tags and attributes, and only web addresses', () => {
		for (const text of HOSTILE) expectInert(html(text));
	});

	it('does the same for an artifact, which the same renderer draws', () => {
		for (const text of HOSTILE) {
			const out = renderMarkdown(text);
			expectInert(out);
			expect(out).not.toMatch(/[\u202a-\u202e\u2066-\u2069]/);
		}
		expect(renderMarkdown('<script>alert(1)</script>')).toContain('&lt;script&gt;');
		expect(renderMarkdown('[a](JaVaScRiPt:alert(1))')).toContain('[a](JaVaScRiPt:alert(1))');
		expect(renderMarkdown('![x](https://example.com/p.png)')).toBe(
			'<p><span class="mdimg">x</span></p>\n'
		);
	});

	it('gives an artifact the same limits: a very long one is plain text, in bounded time', () => {
		const started = performance.now();
		const long = renderMarkdown(`# T <b>${'['.repeat(1_000_000)}`);
		expect(long.startsWith('<p class="plain"># T &lt;b&gt;[[[')).toBe(true);
		expectInert(renderMarkdown('['.repeat(MARKDOWN_MAX)));
		expectInert(html('['.repeat(MARKDOWN_MAX)));
		expect(performance.now() - started).toBeLessThan(3000);
	});

	it('shows the real host when the text of a link names another one', () => {
		const shown = (text: string): string => plainText(html(text)).trim();
		expect(html('[https://good.example](https://evil.example)')).toBe(
			'<p><a href="https://evil.example" target="_blank" rel="noopener noreferrer">' +
				'https://good.example</a> <span class="mdhost">(evil.example)</span></p>\n'
		);
		expect(shown('[good.example/login](https://evil.example/x)')).toBe(
			'good.example/login (evil.example)'
		);
		expect(shown('[**www.good.example**](https://evil.example)')).toBe(
			'www.good.example (evil.example)'
		);
		expect(shown('[go\u200bod.example](https://evil.example)')).toContain('(evil.example)');
		expect(shown('[https://good.example@evil.example](https://good.example@evil.example)')).toBe(
			'https://good.example@evil.example (evil.example)'
		);
		// The host is shown as the browser reads it: a look-alike letter shows.
		expect(shown('[example.com](https://ex\u0430mple.com)')).toMatch(/\(xn--[a-z0-9-]+\.com\)$/);
		expect(renderMarkdown('[good.example](https://evil.example)')).toContain(
			'<span class="mdhost">(evil.example)</span>'
		);
		// The same host, or no host in the text: nothing is added.
		for (const text of [
			'[docs](https://example.com/a)',
			'[example.com](https://example.com/a)',
			'[https://www.example.com/a](https://example.com/b)',
			'[EXAMPLE.com](https://example.com)',
			'see https://example.com/a now',
			'[me@example.com](mailto:me@example.com)'
		])
			expect(html(text), text).not.toContain('mdhost');
	});

	it('does not draw a direction character that an entity spells', () => {
		expect(html('safe&#x202E;gnp.exe &#8238;x &#x2066;y')).toBe('<p>safegnp.exe x y</p>\n');
		expect(html('[a&#x202E;b](https://example.com "t&#x202E;t")')).not.toMatch(/\u202e/);
		expect(renderMarkdown('# a&#x202E;b')).toBe('<h1>ab</h1>\n');
		// In code an entity is not decoded: it shows as it was written.
		expect(html('`a&#x202E;b`')).toContain('a&amp;#x202E;b');
	});

	it('shows raw HTML and a refused link as text', () => {
		expect(html('<script>alert(1)</script>')).toContain('&lt;script&gt;alert(1)&lt;/script&gt;');
		expect(html('[a](javascript:alert(1))')).toBe('<p>[a](javascript:alert(1))</p>\n');
		expect(html('[a](JaVaScRiPt:alert(1))')).toContain('[a](JaVaScRiPt:alert(1))');
		expect(html('[a](data:text/html,x)')).toContain('[a](data:text/html,x)');
		expect(html('[a](file:///etc/passwd)')).toContain('[a](file:///etc/passwd)');
		expect(html('[a](blob:https://example.com/1)')).toContain('[a](blob:');
	});

	it('does not draw characters that turn the text round', () => {
		const out = html('safe‮gnp.exe ⁦x⁩ ‪y‬');
		expect(out).toBe('<p>safegnp.exe x y</p>\n');
	});

	it('shows a very long message as plain text', () => {
		const text = `**x** <b>${'a'.repeat(1_000_000)}`;
		const started = performance.now();
		const out = chatBlocks(text);
		expect(performance.now() - started).toBeLessThan(2000);
		expect(out).toHaveLength(1);
		expect(out[0].startsWith('<p class="plain">**x** &lt;b&gt;aaaa')).toBe(true);
	});

	it('renders a long line and a long code block in bounded time', () => {
		const started = performance.now();
		expectInert(html(`a ${'word '.repeat(30_000)}`));
		expectInert(html(`\`\`\`js\n${'const a = "<b>";\n'.repeat(10_000)}\`\`\``));
		expectInert(html('x'.repeat(MARKDOWN_MAX)));
		expect(performance.now() - started).toBeLessThan(5000);
	});

	it('survives deep nesting and repeated markers', () => {
		const started = performance.now();
		const cases = [
			'> '.repeat(5000) + 'deep',
			Array.from({ length: 2000 }, (_, depth) => `${'  '.repeat(depth)}- item`).join('\n'),
			Array.from({ length: 500 }, (_, depth) => `${'> '.repeat(depth)}- x`).join('\n'),
			'['.repeat(20_000),
			'[a]('.repeat(10_000),
			'*a **b '.repeat(10_000),
			'`'.repeat(20_000) + 'x',
			'|'.repeat(20_000) + '\n' + '|-'.repeat(10_000),
			'!['.repeat(10_000),
			'&'.repeat(50_000),
			'<'.repeat(50_000),
			'\\'.repeat(50_001),
			'```\n'.repeat(10_000),
			'- [ ] '.repeat(10_000)
		];
		for (const text of cases) {
			const out = html(text);
			expectInert(out);
			expect(typeof chatText(text)).toBe('string');
		}
		expect(performance.now() - started).toBeLessThan(15_000);
	});
});
