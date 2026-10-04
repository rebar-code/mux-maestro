<script lang="ts">
	import type { Snippet } from 'svelte';
	import Icon from './Icon.svelte';
	import { barKeys, type KeySink } from './reply';
	import { keepFocus } from './reply.svelte';

	/**
	 * The keys a phone keyboard lacks, in one pill that scrolls sideways. With
	 * no text box there is nothing to type into: only the pane's keys show.
	 */
	const {
		reply,
		composer,
		hides = composer,
		leading
	}: {
		reply: KeySink;
		/** A text box takes the strip's text keys. */
		composer: boolean;
		/** Something on this page brings the on-screen keyboard up, so the strip can put it away. */
		hides?: boolean;
		/** A control fixed at the strip's start. */
		leading?: Snippet;
	} = $props();

	const keys = $derived(barKeys(composer));

	/** Put the on-screen keyboard away: whatever takes the typing gives up the focus. */
	function hide(): void {
		const typing = document.activeElement;
		if (typing instanceof HTMLElement) typing.blur();
	}
</script>

<div class="kbar" data-keybar>
	{@render leading?.()}
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
	{#if hides}
		<!-- Fixed at the strip's end. The one control that does not keep the focus: it gives it up. -->
		<button class="hide" type="button" aria-label="Hide keyboard" onclick={hide}>
			<Icon name="keyboardDown" size={17} />
		</button>
	{/if}
</div>

<style>
	.kbar {
		flex: none;
		display: flex;
		align-items: center;
		gap: 8px;
		margin: 0 max(8px, env(safe-area-inset-right)) 6px max(8px, env(safe-area-inset-left));
		padding: 1px 4px;
		border: 1px solid var(--border);
		border-radius: 15px;
		background: #141414;
	}

	.keys {
		flex: 1;
		min-width: 0;
		display: flex;
		align-items: center;
		gap: 5px;
		/* A slim strip: about 60% of a full touch row. */
		height: 28px;
		border-radius: 12px;
		/* Moved by the gesture controller, like the terminal. */
		overflow: hidden;
		-webkit-mask-image: linear-gradient(90deg, #000 86%, transparent);
		mask-image: linear-gradient(90deg, #000 86%, transparent);
	}

	/* The last key can scroll clear of the fade. */
	.keys::after {
		content: '';
		flex: none;
		width: 28px;
		height: 1px;
	}

	.keys button {
		position: relative;
		flex: none;
		min-width: 28px;
		height: 23px;
		padding: 0 8px;
		border-radius: 8px;
		background: #0c0c0c;
		font-size: 11.5px;
	}

	.keys button::after {
		content: '';
		position: absolute;
		inset: -3px -2px;
	}

	.keys button.on {
		background: var(--accent);
		color: #fff;
	}

	.keys button:active {
		filter: brightness(1.4);
	}

	.hide {
		position: relative;
		/* Its touch area reaches past the slim strip: it stays on top there. */
		z-index: 1;
		flex: none;
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 34px;
		height: 23px;
		border-radius: 8px;
		color: #cfcfcf;
	}

	/* The look is the strip's; the touch area is a full 44pt. */
	.hide::after {
		content: '';
		position: absolute;
		left: 50%;
		top: 50%;
		width: var(--hit);
		height: var(--hit);
		transform: translate(-50%, -50%);
	}

	.hide:active {
		background: #0c0c0c;
	}
</style>
