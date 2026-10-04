import hljs from 'highlight.js/lib/common';
import MarkdownIt from 'markdown-it';

// Artifact text is untrusted. Raw HTML in markdown is off, so it comes out as
// text; markdown-it also refuses `javascript:`, `vbscript:` and `data:` links.
// Images are off too: a remote one would tell its server the file was read.
const md = new MarkdownIt({ html: false, linkify: true, highlight: block });
md.disable('image');

const escape = md.utils.escapeHtml;

/** A code block. `data-hscroll` lets a long line scroll before a tab changes. */
function block(code: string, language: string): string {
	return `<pre class="hljs" data-hscroll><code>${highlighted(code, language)}</code></pre>`;
}

function highlighted(code: string, language: string): string {
	if (language && hljs.getLanguage(language)) {
		try {
			return hljs.highlight(code, { language, ignoreIllegals: true }).value;
		} catch {
			// Fall through to plain text.
		}
	}
	return escape(code);
}

md.renderer.rules.code_block = (tokens, index) => block(tokens[index].content, '');

const linkOpen = md.renderer.rules.link_open;
md.renderer.rules.link_open = (tokens, index, options, env, self) => {
	tokens[index].attrSet('target', '_blank');
	tokens[index].attrSet('rel', 'noopener noreferrer');
	return linkOpen
		? linkOpen(tokens, index, options, env, self)
		: self.renderToken(tokens, index, options);
};

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
export function renderMarkdown(text: string): string {
	return md.render(withFrontMatter(text));
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
