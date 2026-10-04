<script lang="ts">
	import { canAnswer } from './reply';
	import type { Prompt } from './types';

	const {
		id,
		prompt,
		readonly = false,
		answering = null,
		onanswer,
		oncancel,
		onterminal
	}: {
		/** Names what the pane waits on. */
		id: string;
		/** `null`: the pane waits on something with no readable choices. */
		prompt: Prompt | null;
		/** The options are shown, not offered: this phone may not answer. */
		readonly?: boolean;
		/** The option an answer in flight picked, or that it cancels. */
		answering?: number | 'cancel' | null;
		onanswer?: (option: number) => void;
		/** Dismiss what the pane asks. Not given on a card that only shows. */
		oncancel?: () => void;
		/** Open the pane's own text. Not given when it is already showing. */
		onterminal?: () => void;
	} = $props();

	const permission = $derived(prompt?.kind === 'permission');
	// A question may come with no heading of its own.
	const title = $derived(
		prompt ? prompt.title || (permission ? '' : 'Question') : 'Waiting on a prompt'
	);
	// The terminal has what the card does not: the rest of the text, or all of it.
	// The row the pane's cursor is on: what Enter takes. The mark follows it.
	const selected = $derived(prompt?.selected ?? null);
	// A scrolled menu: the pane has rows the card does not list.
	const scrolled = $derived(prompt?.moreAbove === true || prompt?.moreBelow === true);
	const more = $derived(prompt === null || prompt.truncated === true || scrolled);
</script>

<div
	class="card"
	data-prompt={id}
	data-kind={prompt?.kind ?? 'bare'}
	data-readonly={readonly ? '' : undefined}
>
	{#if title}<h3>{title}</h3>{/if}
	{#if prompt}
		{#if prompt.detail || prompt.truncated}
			<pre class="mono">{prompt.detail}{#if prompt.truncated}<span class="more" data-more>…</span
					>{/if}</pre>
		{/if}
		{#if prompt.question}<p class="q" class:main={!permission}>{prompt.question}</p>{/if}
	{/if}
	{#if prompt?.options.length || scrolled || (more && onterminal) || oncancel}
		<div class="opts">
			{#each prompt?.options ?? [] as option, index (option.n)}
				{#if readonly || !canAnswer(option.n)}
					<div
						class="opt"
						class:cur={option.n === selected}
						aria-current={option.n === selected ? 'true' : undefined}
						data-option={option.n}
					>
						<span class="mark" aria-hidden="true">{option.n === selected ? '❯' : ''}</span>
						<span class="label">{option.label}</span>
						<span class="k">{option.n}</span>
					</div>
				{:else}
					<button
						type="button"
						class="opt"
						class:cur={option.n === selected}
						class:yes={permission && index === 0 && option.n === selected}
						aria-current={option.n === selected ? 'true' : undefined}
						data-option={option.n}
						disabled={answering !== null}
						aria-busy={answering === option.n}
						onclick={() => onanswer?.(option.n)}
					>
						{#if option.n === selected}<span class="mark" aria-hidden="true">❯</span>{/if}
						<span class="label">{option.label}</span>
						<span class="k" aria-hidden="true">{option.n}</span>
					</button>
				{/if}
			{/each}
			{#if scrolled}<p class="rest" data-rest>More choices in the terminal</p>{/if}
			{#if more && onterminal}
				<button type="button" class="opt term" onclick={onterminal}>Show terminal</button>
			{/if}
			{#if oncancel}
				<button
					type="button"
					class="opt term"
					disabled={answering !== null}
					aria-busy={answering === 'cancel'}
					onclick={oncancel}>Cancel</button
				>
			{/if}
		</div>
	{/if}
</div>

<style>
	.card {
		border: 1px solid #5a2320;
		background: #170e0d;
		border-radius: 14px;
		padding: 12px;
	}

	/* Sizes follow the chat's text size. */
	h3 {
		margin: 0 0 8px;
		font-size: 0.8667em;
		color: var(--red);
		font-weight: 600;
	}

	pre {
		margin: 0 0 10px;
		padding: 9px 10px;
		background: #0a0a0a;
		border-radius: 8px;
		font-size: 0.8333em;
		white-space: pre-wrap;
		word-break: break-all;
	}

	.q {
		margin: 0 0 10px;
		overflow-wrap: anywhere;
	}

	h3:last-child {
		margin-bottom: 0;
	}

	/* A question is the thing to read: it stands out from the answers under it. */
	.q.main {
		font-size: 1.0667em;
		font-weight: 600;
	}

	.opts {
		display: flex;
		flex-direction: column;
		gap: 8px;
	}

	.opt {
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

	/* Read-only: a list to read, not a row of things to press. */
	div.opt {
		min-height: 0;
		padding: 2px 2px;
		background: none;
		border: 0;
		border-radius: 0;
		color: #cfcfcf;
	}

	/* The pane's cursor is here: Enter takes this one. */
	button.opt.cur {
		border-color: var(--accent);
		box-shadow: inset 0 0 0 1px var(--accent);
	}

	div.opt.cur {
		color: var(--text);
	}

	.mark {
		flex: none;
		color: var(--accent);
	}

	/* The read-only rows keep one column for the mark, so the labels line up. */
	div.opt .mark {
		width: 1em;
	}

	.opt.yes .mark {
		color: #fff;
	}

	.opt.yes {
		background: var(--accent);
		border-color: var(--accent);
		color: #fff;
	}

	button.opt:not(:disabled):active {
		filter: brightness(1.4);
	}

	.more {
		color: var(--muted);
	}

	.rest {
		margin: 0;
		padding: 0 2px;
		font-size: 0.8667em;
		color: var(--muted);
	}

	.opt.term {
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
		font-size: 0.8em;
	}
</style>
