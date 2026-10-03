import js from '@eslint/js';
import svelte from 'eslint-plugin-svelte';
import globals from 'globals';
import ts from 'typescript-eslint';

export default ts.config(
	js.configs.recommended,
	...ts.configs.recommended,
	...svelte.configs.recommended,
	{
		languageOptions: { globals: { ...globals.browser, ...globals.node } },
		rules: {
			'prefer-const': 'error',
			'@typescript-eslint/no-explicit-any': 'error',
			'no-restricted-syntax': [
				'error',
				{
					selector: "CallExpression[callee.name='$effect']",
					message: 'No $effect: use $derived, event handlers, load, $bindable or {@attach}.'
				},
				{
					selector: "CallExpression[callee.object.name='$effect']",
					message: 'No $effect: use $derived, event handlers, load, $bindable or {@attach}.'
				}
			]
		}
	},
	{
		files: ['src/**/*.ts'],
		ignores: ['src/**/*.test.ts', 'src/service-worker.ts'],
		rules: { '@typescript-eslint/explicit-module-boundary-types': 'error' }
	},
	{
		files: ['**/*.svelte', '**/*.svelte.ts'],
		languageOptions: { parserOptions: { parser: ts.parser } }
	},
	{ ignores: ['.svelte-kit/', 'node_modules/', 'test-results/', 'playwright-report/'] }
);
