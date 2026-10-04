import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

/** The old name of the Maestro. It stays in wire names only. */
const OLD = /managers?\b/i;

/** Wire names and module paths: the literals that keep the old name. */
const WIRE = new Set([
	'manager',
	'manager-delta',
	'manager-spinner',
	'mm.manager',
	'/api/manager',
	'/api/manager/text',
	'/api/manager/dismiss',
	'/api/manager/act',
	'$lib/manager',
	'$lib/manager.svelte',
	'./manager',
	'./manager.svelte',
	'PushManager'
]);

const LITERAL = /'((?:[^'\\\n]|\\.)*)'|"((?:[^"\\\n]|\\.)*)"|`((?:[^`\\]|\\.)*)`/g;

function withoutComments(source: string): string {
	return source
		.replace(/\/\*[\s\S]*?\*\//g, '')
		.replace(/<!--[\s\S]*?-->/g, '')
		.replace(/(^|\s)\/\/.*$/gm, '$1');
}

/** The text nodes of a Svelte or HTML file: what is left outside script, style, tags and `{}`. */
function textNodes(source: string): string[] {
	let markup = source.replace(/<(script|style)[\s\S]*?<\/\1>/g, '');
	for (let last = ''; last !== markup;) {
		last = markup;
		markup = markup.replace(/\{[^{}]*\}/g, '');
	}
	return markup.replace(/<[^<>]*>/g, '\n').split('\n');
}

/** The visible-text literals of one source file that still use the old name. */
function oldNames(file: string, source: string): string[] {
	const code = withoutComments(source);
	const literals = [...code.matchAll(LITERAL)].map((m) => m[1] ?? m[2] ?? m[3] ?? '');
	const texts = file.endsWith('.ts') ? [] : textNodes(code);
	return [...literals.filter((literal) => !WIRE.has(literal)), ...texts]
		.map((text) => text.trim())
		.filter((text) => OLD.test(text));
}

function sources(dir: string): string[] {
	return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
		const path = join(dir, entry.name);
		if (entry.isDirectory()) return sources(path);
		return /\.(svelte|ts|html)$/.test(path) && !path.endsWith('.test.ts') ? [path] : [];
	});
}

describe('oldNames', () => {
	it('finds the old name in a string, an attribute and a text node', () => {
		expect(oldNames('a.ts', "const note = 'Manager is busy';")).toEqual(['Manager is busy']);
		expect(oldNames('a.svelte', '<input aria-label="Ask the manager" />')).toEqual([
			'Ask the manager'
		]);
		expect(oldNames('a.svelte', '<span>✦ Manager</span>')).toEqual(['✦ Manager']);
	});

	it('passes wire names, identifiers and comments', () => {
		expect(oldNames('a.ts', "if (frame.event === 'manager') manager.apply(body);")).toEqual([]);
		expect(oldNames('a.ts', "get('/api/manager'); // the manager home")).toEqual([]);
		expect(oldNames('a.svelte', '<div>{manager.note}</div><!-- Manager row -->')).toEqual([]);
	});
});

describe('the phone app', () => {
	it('calls the agent the Maestro in every text a person reads', () => {
		const found = sources('src').flatMap((file) =>
			oldNames(file, readFileSync(file, 'utf8')).map((text) => `${file}: ${text}`)
		);
		expect(found).toEqual([]);
	});
});
