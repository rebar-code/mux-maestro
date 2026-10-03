<script lang="ts">
	import type { Snippet } from 'svelte';
	import type { Attachment } from 'svelte/attachments';
	import type { FormEventHandler } from 'svelte/elements';
	import TalkButton from './TalkButton.svelte';
	import type { VoiceSink, VoiceTarget } from './voice.svelte';

	/**
	 * A text box and its primary button, for the manager home and for a thread.
	 * With an empty box the button is the voice control of `target`; with text
	 * in the box it sends. A switch that is off on the Mac leaves its control in
	 * place, disabled: `off` for the box, `voiceOn` false for the voice button.
	 */
	// `value` is bound, so the whole pattern is a `let`.
	/* eslint-disable prefer-const */
	let {
		value = $bindable(),
		label,
		target,
		sink,
		voiceOn,
		blocked = false,
		off = false,
		bare = false,
		note = null,
		onsend,
		oninput,
		onbeforeinput,
		box,
		leading
	}: {
		value: string;
		/** The placeholder, and the box's name. */
		label: string;
		target: VoiceTarget;
		sink: VoiceSink;
		voiceOn: boolean;
		/** Nothing can be sent now. The box still takes text. */
		blocked?: boolean;
		/**
		 * The feature is switched off: the box holds its place and takes nothing.
		 * The caller's `label` then says where the switch is.
		 */
		off?: boolean;
		/** No voice bar sits above: the box draws its own top edge. */
		bare?: boolean;
		/** The status line: what the last send came to. */
		note?: { text: string; bad: boolean } | null;
		onsend: () => void;
		oninput?: FormEventHandler<HTMLInputElement>;
		onbeforeinput?: (event: InputEvent) => void;
		/** Attachment for the text box, for a caller that types into it or moves the focus. */
		box?: Attachment<HTMLInputElement>;
		/** Controls left of the text box. */
		leading?: Snippet;
	} = $props();
	/* eslint-enable prefer-const */

	const canSend = $derived(value.trim() !== '');

	function submit(event: SubmitEvent): void {
		event.preventDefault();
		if (canSend && !blocked && !off) onsend();
	}
</script>

<form class="compose" class:bare onsubmit={submit} data-compose data-off={off ? '' : undefined}>
	{#if note}
		<div class="note" class:bad={note.bad} role={note.bad ? 'alert' : 'status'} data-note>
			{note.text}
		</div>
	{/if}
	{@render leading?.()}
	<input
		bind:value
		{@attach box}
		placeholder={label}
		aria-label={label}
		enterkeyhint="send"
		autocomplete="off"
		autocapitalize="sentences"
		disabled={off}
		{oninput}
		{onbeforeinput}
	/>
	<!-- Typing is always there: with text in the box the button sends it. -->
	{#if canSend && !off}
		<button class="pill send grow" type="submit" disabled={blocked}>↑ Send</button>
	{:else}
		<TalkButton {target} {sink} off={!voiceOn} />
	{/if}
</form>

<style>
	.compose {
		flex: none;
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 8px;
		margin: 0;
		/* With the keyboard up there is no home indicator under the box. */
		padding: 6px max(10px, env(safe-area-inset-right))
			calc(10px + var(--safe-bottom, env(safe-area-inset-bottom)))
			max(10px, env(safe-area-inset-left));
		background: var(--bar);
	}

	/*
	 * With no voice bar above it, the text box draws the top edge itself. The
	 * edge and the padding add up to the same height, so the box does not move
	 * when a switch on the Mac brings the voice bar in.
	 */
	.compose.bare {
		padding-top: 5px;
		border-top: 1px solid var(--border);
	}

	.note {
		flex: 0 0 100%;
		padding: 0 4px;
		font-size: 12.5px;
		color: var(--muted);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.note.bad {
		color: var(--red);
	}

	input {
		flex: 1;
		min-width: 0;
		min-height: var(--hit);
		padding: 10px 14px;
		border-radius: 22px;
		border: 1px solid var(--border);
		background: var(--surface);
		color: var(--text);
		/* 16px: a smaller box makes iOS zoom the page on focus. */
		font: inherit;
		font-size: 16px;
		outline: none;
	}

	/* Off, not broken: the label stays readable. */
	input:disabled {
		opacity: 1;
		color: var(--muted);
		-webkit-text-fill-color: var(--muted);
	}

	input:disabled::placeholder {
		color: var(--muted);
		opacity: 1;
	}

	input:focus-visible {
		border-color: var(--accent);
	}

	.pill {
		position: relative;
		flex: none;
		height: 40px;
		padding: 0 16px;
		border-radius: 20px;
		background: var(--accent);
		color: #fff;
		font-weight: 600;
		font-size: 14px;
		white-space: nowrap;
		/* As wide as the voice button, so the text box beside it never moves. */
		min-width: 104px;
	}
</style>
