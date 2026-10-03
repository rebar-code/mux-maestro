<script lang="ts">
	import { QUERY_MAX, type Find } from './find.svelte';

	const { find }: { find: Find } = $props();

	function onkeydown(event: KeyboardEvent): void {
		if (event.key === 'Enter') {
			event.preventDefault();
			if (event.shiftKey) find.previous();
			else find.next();
		} else if (event.key === 'Escape') find.close();
	}
</script>

<div class="findbar" role="search">
	<label class="field">
		<input
			type="search"
			enterkeyhint="search"
			autocomplete="off"
			autocapitalize="off"
			autocorrect="off"
			spellcheck="false"
			maxlength={QUERY_MAX}
			placeholder="Find in session"
			aria-label="Find in session"
			bind:value={find.query}
			oninput={find.typed}
			{onkeydown}
			{@attach (node) => node.focus()}
		/>
	</label>
	<span class="count" aria-live="polite" data-find-count>{find.label}</span>
	<button class="tb" aria-label="Previous match" disabled={find.count === 0} onclick={find.previous}
		>↑</button
	>
	<button class="tb" aria-label="Next match" disabled={find.count === 0} onclick={find.next}
		>↓</button
	>
	<button class="tb" aria-label="Close find" onclick={find.close}>✕</button>
</div>

<style>
	.findbar {
		display: flex;
		align-items: center;
		gap: 8px;
		flex: none;
		padding: 0 max(8px, env(safe-area-inset-right)) 0 max(8px, env(safe-area-inset-left));
		min-height: var(--hit);
		border-bottom: 1px solid var(--border);
		background: var(--surface);
	}

	/* The box keeps its look; a tap anywhere in the bar's height reaches it. */
	.field {
		flex: 1;
		min-width: 0;
		display: flex;
		align-items: center;
		min-height: var(--hit);
	}

	input {
		flex: 1;
		min-width: 0;
		height: 34px;
		background: var(--bg);
		border: 1px solid var(--border);
		border-radius: 8px;
		padding: 0 10px;
		color: var(--text);
		font: inherit;
		/* Under 16px, iOS zooms the page when the box takes focus. */
		font-size: 16px;
		outline: none;
		appearance: none;
	}

	input::-webkit-search-cancel-button {
		display: none;
	}

	.count {
		flex: none;
		min-width: 34px;
		text-align: right;
		font-size: 12px;
		color: var(--muted);
		font-variant-numeric: tabular-nums;
	}

	.tb {
		margin: 0 -3px;
	}
</style>
