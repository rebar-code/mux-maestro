import hljs from 'highlight.js/lib/common';
import MarkdownIt from 'markdown-it';
import type { Hit } from './find';

// The text is untrusted: an artifact, or what an agent said. Raw HTML in
// markdown is off, so it comes out as text. Everything this file returns is
// either that escaped text or a tag written here.
const md = new MarkdownIt({ html: false, linkify: true });

const escape = md.utils.escapeHtml;

/** The longest code that is highlighted; a longer one is plain. */
const HIGHLIGHT_MAX = 50_000;
/** The longest message that is parsed as markdown; a longer one is plain text. */
export const MARKDOWN_MAX = 200_000;

/**
 * A code block. `data-hscroll` lets a long line scroll before a tab changes.
 * The button has no text of its own: a find never lands on it.
 */
function block(code: string, language: string): string {
	return (
		'<div class="codeblock"><button type="button" class="copy" data-copy aria-label="Copy"></button>' +
		`<pre class="hljs" data-hscroll><code>${highlighted(code, language)}</code></pre></div>\n`
	);
}

function highlighted(code: string, language: string): string {
	if (language && code.length <= HIGHLIGHT_MAX && hljs.getLanguage(language)) {
		try {
			return hljs.highlight(code, { language, ignoreIllegals: true }).value;
		} catch {
			// Fall through to plain text.
		}
	}
	return escape(code);
}

md.renderer.rules.code_block = (tokens, index) => block(tokens[index].content, '');
md.renderer.rules.fence = (tokens, index) =>
	block(tokens[index].content, tokens[index].info.trim().split(/\s+/)[0]);

// Characters a browser drops from an address before it reads the scheme, and
// ones that are not drawn at all.
// eslint-disable-next-line no-control-regex
const UNSEEN = /[\u0000-\u0020\u007f-\u009f\u00ad\u200b-\u200f\u2028-\u202e\u2060-\u2069\ufeff]/g;
const SCHEME = /^([a-z][a-z0-9+.-]*):/i;
const ALLOWED = new Set(['http', 'https', 'mailto']);

// A link with any other scheme (`javascript:`, `data:`, `vbscript:`, `file:`,
// `blob:`, ...) is not a link: markdown-it leaves its source as text. An
// address with no scheme is a path, and a path never gets an `href`.
md.validateLink = (url) => {
	const scheme = SCHEME.exec(url.replace(UNSEEN, ''))?.[1].toLowerCase();
	return scheme === undefined || ALLOWED.has(scheme);
};

// Only an address written with its scheme is made a link by itself: with
// guessing on, `notes.md` and `main.rs` would be web links.
md.linkify.set({ fuzzyLink: false, fuzzyEmail: false }).add('ftp:', null).add('//', null);

const LOCAL_HOST = /^(localhost|.+\.localhost|127(\.\d+){3}|0\.0\.0\.0|\[::1?\])$/i;

type Target =
	| { kind: 'web'; href: string }
	| { kind: 'local'; port: number; rest: string }
	| { kind: 'path'; path: string };

/** A path as it was written: no query, no fragment, no `./`. */
function pathOf(address: string): string {
	const bare = address.replace(/[?#].*$/, '');
	try {
		return decodeURI(bare).replace(/^\.\//, '');
	} catch {
		return bare.replace(/^\.\//, '');
	}
}

/** Where a link goes. Only `web` is an address the page may open itself. */
function targetOf(address: string): Target {
	if (/^mailto:/i.test(address)) return { kind: 'web', href: address };
	if (!/^https?:\/\//i.test(address)) return { kind: 'path', path: pathOf(address) };
	try {
		const url = new URL(address);
		if (!LOCAL_HOST.test(url.hostname)) return { kind: 'web', href: address };
		const port = Number(url.port) || (url.protocol === 'https:' ? 443 : 80);
		return { kind: 'local', port, rest: `${url.pathname}${url.search}${url.hash}` };
	} catch {
		return { kind: 'path', path: pathOf(address) };
	}
}

// A web link opens in a new tab. A file path and a local address have no
// `href`: the view decides what a tap on one does, and without a view it
// does nothing.
// A name in a link's text that reads as a host: `good.example`, with or
// without a scheme in front of it.
const NAMED_HOST =
	/(?:[a-z][a-z0-9+.-]*:\/\/)?((?:[a-z0-9\u00a1-\uffff-]+\.)+[a-z\u00a1-\uffff][a-z0-9\u00a1-\uffff-]*)/gi;

/** A host as a browser reads it, without `www.`; null when it is not one. */
function hostOf(address: string): string | null {
	try {
		return new URL(address).hostname.toLowerCase().replace(/^www\./, '');
	} catch {
		return null;
	}
}

/**
 * The host a web link goes to, when its text names another one:
 * `[good.example](https://evil.example)`. Null when the text names no host,
 * or the same one.
 */
function otherHost(text: string, href: string): string | null {
	const real = hostOf(href);
	if (real === null || !/^https?:/i.test(href)) return null;
	for (const [, named] of text.replace(UNSEEN, '').matchAll(NAMED_HOST)) {
		if (hostOf(`http://${named}`) !== real) return real;
	}
	return null;
}

md.renderer.rules.link_open = (tokens, index, options, _env, self) => {
	const token = tokens[index];
	const target = targetOf(String(token.attrGet('href') ?? ''));
	if (target.kind === 'web') {
		// What the link shows, up to its end.
		let close = index + 1;
		let text = '';
		for (; close < tokens.length && tokens[close].type !== 'link_close'; close += 1) {
			text += tokens[close].content;
		}
		const host = otherHost(text, target.href);
		if (host !== null && tokens[close]) tokens[close].meta = { host };
		token.attrs = [
			['href', target.href],
			['target', '_blank'],
			['rel', 'noopener noreferrer']
		];
	} else if (target.kind === 'local') {
		token.attrs = [
			['data-local', String(target.port)],
			['data-rest', target.rest],
			['role', 'link'],
			['tabindex', '0']
		];
	} else {
		token.attrs = [
			['data-file', target.path],
			['role', 'link'],
			['tabindex', '0']
		];
	}
	return self.renderToken(tokens, index, options);
};

// The text of a link can name one site and the link go to another. The real
// host is then shown after the link, outside it.
md.renderer.rules.link_close = (tokens, index) => {
	const host: unknown = tokens[index].meta?.host;
	return typeof host === 'string' ? `</a> <span class="mdhost">(${escape(host)})</span>` : '</a>';
};

// No image is loaded from here: a remote one would tell its server that the
// message was read, and from where. An image is its alt text in a chip; the
// view puts a picture in it only for a file of the thread.
md.renderer.rules.image = (tokens, index, _options, _env, self) => {
	const token = tokens[index];
	const target = targetOf(String(token.attrGet('src') ?? ''));
	const alt = self.renderInlineAsText(token.children ?? [], md.options, {});
	const name = target.kind === 'path' ? (target.path.split('/').pop() ?? '') : '';
	const path = target.kind === 'path' ? ` data-img="${escape(target.path)}"` : '';
	return `<span class="mdimg"${path}>${escape(alt || name || 'image')}</span>`;
};

// A wide table scrolls by itself.
md.renderer.rules.table_open = () => '<div class="tablebox" data-hscroll><table>\n';
md.renderer.rules.table_close = () => '</table></div>\n';

// `- [ ]` and `- [x]`: a box that shows the state and cannot be changed.
md.core.ruler.push('task', (state) => {
	const tokens = state.tokens;
	for (let i = 2; i < tokens.length; i += 1) {
		if (tokens[i].type !== 'inline' || tokens[i - 1].type !== 'paragraph_open') continue;
		if (tokens[i - 2].type !== 'list_item_open') continue;
		const first = tokens[i].children?.[0];
		const found = first?.type === 'text' ? /^\[([ xX])\](?: |$)/.exec(first.content) : null;
		if (!first || !found) continue;
		first.content = first.content.slice(found[0].length);
		const box = new state.Token('task_box', '', 0);
		box.meta = { checked: found[1] !== ' ' };
		tokens[i].children?.unshift(box);
		tokens[i - 2].attrJoin('class', 'task');
	}
});
md.renderer.rules.task_box = (tokens, index) =>
	`<input type="checkbox" disabled${tokens[index].meta?.checked ? ' checked' : ''}> `;

// Chat keeps the line breaks of its text.
md.renderer.rules.softbreak = (_tokens, _index, _options, env) => (env?.chat ? '<br>\n' : '\n');

// Characters that change the direction text is drawn in. They can make a
// name or an address read as another one, so they are not drawn.
const BIDI = /[\u202a-\u202e\u2066-\u2069]/g;

/** Text that is not parsed: escaped, with its line breaks kept by the style. */
const plainBlock = (text: string): string[] => [`<p class="plain">${escape(text)}</p>\n`];

/** YAML front matter as a code block: markdown would draw its keys as a heading. */
function withFrontMatter(text: string): string {
	const lines = text.replace(/\r\n/g, '\n').split('\n');
	if (lines[0] !== '---') return lines.join('\n');
	const close = lines.indexOf('---', 1);
	if (close < 2) return lines.join('\n');
	lines[0] = '```yaml';
	lines[close] = '```';
	return lines.join('\n');
}

/** Markdown as HTML that is safe to put in the page. */
export function renderMarkdown(source: string): string {
	const text = source.replace(BIDI, '');
	if (text.length > MARKDOWN_MAX) return plainBlock(text).join('');
	try {
		return md.render(withFrontMatter(text), {}).replace(BIDI, '');
	} catch {
		return plainBlock(text).join('');
	}
}

/** A message as HTML, one string for each top-level block. */
function blocksOf(source: string): string[] {
	const text = source.replace(BIDI, '');
	if (text.length > MARKDOWN_MAX) return plainBlock(text);
	try {
		const env = { chat: true };
		const tokens = md.parse(text, env);
		const out: string[] = [];
		let depth = 0;
		let from = 0;
		for (let i = 0; i < tokens.length; i += 1) {
			depth += tokens[i].nesting;
			if (depth !== 0) continue;
			// An entity can spell a direction character: the parser has decoded it by now.
			out.push(md.renderer.render(tokens.slice(from, i + 1), md.options, env).replace(BIDI, ''));
			from = i + 1;
		}
		return out;
	} catch {
		return plainBlock(text);
	}
}

interface Entry {
	blocks: string[];
	/** The text each block shows, worked out when a find first asks. */
	plain: string[] | null;
}

/** How many characters of messages are kept rendered. */
const CACHE_CHARS = 2_000_000;
const cache = new Map<string, Entry>();
let held = 0;

/** A message is parsed once: the same text again is a lookup. */
function entry(text: string): Entry {
	const found = cache.get(text);
	if (found) return found;
	const made: Entry = { blocks: blocksOf(text), plain: null };
	cache.set(text, made);
	held += text.length;
	for (const oldest of cache.keys()) {
		if (held <= CACHE_CHARS || oldest === text) break;
		held -= oldest.length;
		cache.delete(oldest);
	}
	return made;
}

/**
 * A chat message as HTML that is safe to put in the page: one string for each
 * top-level block, so a message that grows redraws only the block that changed.
 */
export function chatBlocks(text: string): string[] {
	return entry(text).blocks;
}

let live: { text: string; blocks: string[] } | null = null;

/**
 * `chatBlocks` for a reply that is still arriving. Each update is a new text,
 * so only the newest is kept: a long reply does not fill the cache with its
 * own beginnings and push the finished messages out of it.
 */
export function liveBlocks(text: string): string[] {
	if (live?.text !== text) live = { text, blocks: blocksOf(text) };
	return live.blocks;
}

const ENTITY: Record<string, string> = {
	'&amp;': '&',
	'&lt;': '<',
	'&gt;': '>',
	'&quot;': '"',
	'&#x27;': "'",
	'&#39;': "'"
};
// A tag, an entity, or a run of text. Text and attributes are escaped, so a
// `<` always starts a tag and a `>` always ends one.
const PIECE = /<[^>]*>|&(?:amp|lt|gt|quot|#x27|#39);|[^<&]+|[<&]/g;

/** The text a reader sees in `html`. */
export function plainText(html: string): string {
	let out = '';
	for (const [piece] of html.matchAll(PIECE)) {
		if (piece.length > 1 && piece[0] === '<') continue;
		out += ENTITY[piece] ?? piece;
	}
	return out;
}

function plainOf(text: string): string[] {
	const made = entry(text);
	made.plain ??= made.blocks.map(plainText);
	return made.plain;
}

/** The text a chat message shows once rendered: what a find looks in. */
export function chatText(text: string): string {
	return plainOf(text).join('');
}

/**
 * `html` with each hit in a `<mark>`. `base` is where this HTML's text starts
 * in the text the hits were found in. A hit that crosses a tag gets a mark on
 * each side of it, so the tags stay nested as they were.
 */
export function markHits(html: string, hits: Hit[], base: number, current: number): string {
	let out = '';
	let at = base;
	let next = 0;
	let opened = -1;
	for (const [piece] of html.matchAll(PIECE)) {
		if (piece.length > 1 && piece[0] === '<') {
			out += piece;
			continue;
		}
		// An entity is one character of text; it is never cut.
		const whole = piece[0] === '&' && piece.length > 1;
		const length = whole ? 1 : piece.length;
		let done = 0;
		while (done < length) {
			while (next < hits.length && hits[next].range[1] <= at + done) next += 1;
			const hit = hits[next];
			const start = hit ? Math.max(hit.range[0] - at, done) : length;
			if (start > done) {
				const stop = Math.min(start, length);
				out += whole ? piece : piece.slice(done, stop);
				done = stop;
				continue;
			}
			const stop = Math.min(hit.range[1] - at, length);
			const cur = hit.index === current;
			const first = cur && opened !== hit.index ? ' data-find-current' : '';
			opened = hit.index;
			out += `<mark${cur ? ' class="cur"' : ''}${first}>${whole ? piece : piece.slice(done, stop)}</mark>`;
			done = stop;
		}
		at += length;
	}
	return out;
}

/** `chatBlocks`, with the hits of a find marked. The hits are ranges in `chatText`. */
export function markedBlocks(text: string, hits: Hit[], current: number): string[] {
	const plain = plainOf(text);
	let base = 0;
	return chatBlocks(text).map((html, index) => {
		const start = base;
		base += plain[index].length;
		const mine = hits.filter((hit) => hit.range[0] < base && hit.range[1] > start);
		return mine.length ? markHits(html, mine, start, current) : html;
	});
}

/** The paths of the images a chat message names. */
export function imagePaths(text: string): string[] {
	const out: string[] = [];
	for (const html of chatBlocks(text)) {
		for (const [, path] of html.matchAll(/ data-img="([^"]*)"/g)) out.push(plainText(path));
	}
	return out;
}

const NAMES: Record<string, string> = { makefile: 'makefile', dockerfile: 'dockerfile' };
const EXTENSIONS: Record<string, string> = {
	mjs: 'javascript',
	cjs: 'javascript',
	jsx: 'javascript',
	tsx: 'typescript',
	svelte: 'xml',
	vue: 'xml',
	htm: 'xml',
	html: 'xml',
	zsh: 'bash',
	fish: 'bash',
	yml: 'yaml',
	toml: 'ini',
	conf: 'ini',
	h: 'c',
	cc: 'cpp',
	cxx: 'cpp',
	hpp: 'cpp',
	kts: 'kotlin',
	sass: 'scss'
};

/** A file's text as highlighted HTML, by its name. An unknown type is plain text. */
export function renderCode(text: string, name: string): string {
	const base = name.toLowerCase();
	const extension = base.includes('.') ? base.slice(base.lastIndexOf('.') + 1) : '';
	return highlighted(text, NAMES[base] ?? EXTENSIONS[extension] ?? extension);
}
