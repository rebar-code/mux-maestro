<script lang="ts">
	import { barKeys } from './reply';
	import { keepFocus, type Reply } from './reply.svelte';

	/**
	 * The keys a phone keyboard lacks, in one pill that scrolls sideways. With
	 * no text box there is nothing to type into: only the pane's keys show.
	 */
	const { reply, composer }: { reply: Reply; composer: boolean } = $props();

	const keys = $derived(barKeys(composer));
</script>

<div class="kbar" data-keybar>
	<div class="keys" data-hscroll role="group" aria-label="Keys">
		{#each keys as key (key.label)}
			<button
				class="mono"
				class:on={key.ctrl && reply.ctrl}
				type="button"
				aria-label={key.aria}
				aria-pressed={key.ctrl ? reply.ctrl : undefined}
				{@attach keepFocus}
				onclick={() => reply.tap(key)}>{key.label}</button
			>
		{/each}
	</div>
	{#if composer}
		<button
			class="tb hide"
			type="button"
			aria-label="Hide keyboard"
			onclick={() => reply.input?.blur()}>⌨</button
		>
	{/if}
</div>

<style>
	.kbar {
		flex: none;
		display: flex;
		align-items: center;
		gap: 8px;
		margin: 0 max(8px, env(safe-area-inset-right)) 8px max(8px, env(safe-area-inset-left));
		padding: 2px 4px 2px 6px;
		border: 1px solid var(--border);
		border-radius: 24px;
		background: #141414;
	}

	.keys {
		flex: 1;
		min-width: 0;
		display: flex;
		align-items: center;
		gap: 8px;
		/* As tall as a touch area: each key's reaches past its look. */
		height: var(--hit);
		border-radius: 16px;
		/* Moved by the gesture controller, like the terminal. */
		overflow: hidden;
		-webkit-mask-image: linear-gradient(90deg, #000 86%, transparent);
		mask-image: linear-gradient(90deg, #000 86%, transparent);
	}

	/* The last key can scroll clear of the fade. */
	.keys::after {
		content: '';
		flex: none;
		width: 36px;
		height: 1px;
	}

	.keys button {
		position: relative;
		flex: none;
		min-width: var(--hit);
		height: 38px;
		padding: 0 13px;
		border-radius: 13px;
		background: #0c0c0c;
		font-size: 14px;
	}

	.keys button::after {
		content: '';
		position: absolute;
		inset: -3px 0;
	}

	.keys button.on {
		background: var(--accent);
		color: #fff;
	}

	.keys button:active {
		filter: brightness(1.4);
	}

	.hide {
		font-size: 17px;
	}
</style>
