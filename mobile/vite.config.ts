import { createHash } from 'node:crypto';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import adapter from '@sveltejs/adapter-static';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vitest/config';

// The built bundle is committed, so the same sources must build the same files.
// SvelteKit's default version is the build time; use a hash of the inputs.
function sourceHash(): string {
	const hash = createHash('sha1');
	const walk = (dir: string): void => {
		for (const entry of readdirSync(dir, { withFileTypes: true }).sort((a, b) =>
			a.name.localeCompare(b.name)
		)) {
			const path = join(dir, entry.name);
			if (entry.isDirectory()) walk(path);
			else hash.update(path).update(readFileSync(path));
		}
	};
	walk('src');
	walk('static');
	hash.update(readFileSync('pnpm-lock.yaml'));
	return hash.digest('hex').slice(0, 12);
}

const out = '../app/MuxMaestro/Resources/mobile';

export default defineConfig({
	plugins: [
		sveltekit({
			compilerOptions: {
				runes: ({ filename }) =>
					filename.split(/[/\\]/).includes('node_modules') ? undefined : true
			},
			adapter: adapter({ pages: out, assets: out, fallback: 'index.html' }),
			version: { name: sourceHash() }
		})
	],
	test: { include: ['src/**/*.test.ts'] }
});
