<script lang="ts">
	import type { Prompt } from './types';

	const {
		prompt,
		answering,
		onanswer,
		onterminal
	}: {
		prompt: Prompt;
		/** The option an answer in flight picked. */
		answering: number | null;
		onanswer: (option: number) => void;
		/** Open the pane's own text. Not given when it is already showing. */
		onterminal?: () => void;
	} = $props();

	const permission = $derived(prompt.kind === 'permission');
	// A question may come with no heading of its own.
	const title = $derived(prompt.title || (permission ? '' : 'Question'));
</script>

<div class="card" data-prompt={prompt.id} data-kind={prompt.kind}>
	{#if title}<h3>{title}</h3>{/if}
	{#if prompt.detail || prompt.truncated}
		<pre class="mono">{prompt.detail}{#if prompt.truncated}<span class="more" data-more>…</span
				>{/if}</pre>
	{/if}
	{#if prompt.question}<p class="q">{prompt.question}</p>{/if}
	<div class="opts">
		{#each prompt.options as option, index (option.n)}
			<button
				type="button"
				class:yes={permission && index === 0}
				disabled={answering !== null}
				aria-busy={answering === option.n}
				onclick={() => onanswer(option.n)}
			>
				<span class="label">{option.label}</span>
				<span class="k" aria-hidden="true">{option.n}</span>
			</button>
		{/each}
		{#if prompt.truncated && onterminal}
			<button type="button" class="term" onclick={onterminal}>Show terminal</button>
		{/if}
	</div>
</div>

<style>
	.card {
		border: 1px solid #5a2320;
		background: #170e0d;
		border-radius: 14px;
		padding: 12px;
	}

	h3 {
		margin: 0 0 8px;
		font-size: 13px;
		color: var(--red);
		font-weight: 600;
	}

	pre {
		margin: 0 0 10px;
		padding: 9px 10px;
		background: #0a0a0a;
		border-radius: 8px;
		font-size: 12.5px;
		white-space: pre-wrap;
		word-break: break-all;
	}

	.q {
		margin: 0 0 10px;
		overflow-wrap: anywhere;
	}

	.opts {
		display: flex;
		flex-direction: column;
		gap: 8px;
	}

	button {
		display: flex;
		align-items: baseline;
		gap: 10px;
		min-height: var(--hit);
		padding: 11px 12px;
		border-radius: 10px;
		background: var(--surface);
		border: 1px solid var(--border);
		text-align: left;
		font-weight: 500;
	}

	button.yes {
		background: var(--accent);
		border-color: var(--accent);
		color: #fff;
	}

	button:not(:disabled):active {
		filter: brightness(1.4);
	}

	.more {
		color: var(--muted);
	}

	button.term {
		justify-content: center;
		background: none;
		color: var(--muted);
	}

	.label {
		flex: 1;
		min-width: 0;
		overflow-wrap: anywhere;
	}

	.k {
		flex: none;
		color: rgba(255, 255, 255, 0.55);
		font-size: 12px;
	}
</style>
