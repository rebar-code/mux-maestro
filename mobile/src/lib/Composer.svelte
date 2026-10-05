<script lang="ts">
	import type { Snippet } from 'svelte';
	import type { Attachment } from 'svelte/attachments';
	import type { FormEventHandler } from 'svelte/elements';
	import { limitLabel } from './compose';
	import GrowingText from './GrowingText.svelte';
	import Icon from './Icon.svelte';
	import type { SendStage } from './reply';
	import { keepFocus } from './reply.svelte';
	import TalkButton from './TalkButton.svelte';
	import { voice, type VoiceSink, type VoiceTarget } from './voice.svelte';

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
		sending = false,
		busy = false,
		stage = 'idle',
		off = false,
		bare = false,
		note = null,
		onsend,
		oninput,
		onbeforeinput,
		onpaste,
		onfocus,
		onblur,
		box,
		leading,
		above
	}: {
		value: string;
		/** The placeholder, and the box's name. */
		label: string;
		target: VoiceTarget;
		sink: VoiceSink;
		voiceOn: boolean;
		/** Nothing can be sent now. The box still takes text. */
		blocked?: boolean;
		/** A send is on its way: the button shows it, and takes no second tap. */
		sending?: boolean;
		/** The agent is mid-turn: Send is a soft submit, and the button shows it. */
		busy?: boolean;
		/** Where the two-stage send is: see `sendReduce`. */
		stage?: SendStage;
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
		oninput?: FormEventHandler<HTMLTextAreaElement>;
		onbeforeinput?: (event: InputEvent) => void;
		/** Attachment for the text box, for a caller that types into it or moves the focus. */
		box?: Attachment<HTMLTextAreaElement>;
		onpaste?: (event: ClipboardEvent) => void;
		onfocus?: () => void;
		onblur?: () => void;
		/** Controls left of the text box. */
		leading?: Snippet;
		/** A row above the text box, as wide as the composer. */
		above?: Snippet;
	} = $props();
	/* eslint-enable prefer-const */

	const canSend = $derived(value.trim() !== '');
	/** A take is open here: it can be dropped. */
	const recording = $derived(voiceOn && voice.statusOf(target) === 'recording');
	/** Text queued to a busy agent keeps the button on screen with nothing in the box. */
	const staged = $derived(stage !== 'idle');
	/**
	 * What the next tap does, and so what the button shows. Three shapes, not
	 * three colours: the arrow, the arrow over the queue's lines, the arrow
	 * over a stop square. Text in the box is never an interrupt.
	 */
	const face = $derived.by(() => {
		if (stage === 'armed' && !canSend)
			return { look: 'interrupt', icon: 'interrupt', name: 'Interrupt and send' } as const;
		if (busy || staged)
			return {
				look: 'queue',
				icon: 'sendQueued',
				name: canSend ? 'Send, queued' : 'Queued'
			} as const;
		return { look: 'send', icon: 'send', name: 'Send' } as const;
	});

	/** Over what the Mac takes in one message: said before anything is sent. */
	const tooLong = $derived(limitLabel(value));
	const shown = $derived(tooLong ? { text: tooLong, bad: true } : note);

	function send(): void {
		if ((canSend || staged) && !blocked && !sending && !off && !tooLong) onsend();
	}

	/** Enter on real keys sends text. It never arms or fires the interrupt. */
	function enter(): void {
		if (canSend) send();
	}

	function submit(event: SubmitEvent & { currentTarget: HTMLFormElement }): void {
		event.preventDefault();
		const box = event.currentTarget.querySelector('textarea');
		// A keyboard that is up stays up for the next message; one that was put away stays away.
		const typing = box !== null && document.activeElement === box;
		send();
		if (typing) box.focus();
	}
</script>

<form class="compose" class:bare onsubmit={submit} data-compose data-off={off ? '' : undefined}>
	{#if shown}
		<div class="note" class:bad={shown.bad} role={shown.bad ? 'alert' : 'status'} data-note>
			{shown.text}
		</div>
	{/if}
	{@render above?.()}
	{@render leading?.()}
	<GrowingText
		bind:value
		{label}
		disabled={off}
		onsend={enter}
		{oninput}
		{onbeforeinput}
		{onpaste}
		{onfocus}
		{onblur}
		{box}
	/>
	{#if recording}
		<button
			class="cancel grow"
			type="button"
			data-cancel
			{@attach keepFocus}
			onclick={() => voice.cancel(target)}>Cancel</button
		>
	{/if}
	<!-- Typing is always there: with text in the box the button sends it. -->
	{#if (canSend || staged) && !off}
		<!-- An icon alone: the row's width is the text box's. The name is for a screen reader. -->
		<button
			class="send grow"
			class:armed={face.look === 'interrupt'}
			type="submit"
			disabled={blocked || sending || tooLong !== null}
			aria-busy={sending}
			aria-label={sending ? 'Sending' : face.name}
			data-send={face.look}
			{@attach keepFocus}
		>
			<!-- While a send is out, the sign takes the arrow's place. -->
			{#if sending}
				<i class="busy" data-send-busy aria-hidden="true"></i>
			{:else}
				<Icon name={face.icon} size={20} />
			{/if}
		</button>
		<!-- The armed button is said aloud when it arms, not only when it is found. -->
		<span class="said" role="status">{face.look === 'interrupt' ? 'Interrupt armed' : ''}</span>
	{:else}
		<TalkButton {target} {sink} off={!voiceOn} />
	{/if}
</form>

<style>
	.compose {
		flex: none;
		display: flex;
		flex-wrap: wrap;
		/* The buttons stay on the box's last line as it grows. */
		align-items: flex-end;
		gap: 8px;
		margin: 0;
		/*
		 * The bottom inset is counted once. With the keyboard up there is no home
		 * indicator under the box (`--safe-bottom`); on the manager home the board
		 * takes the inset over once it shows under the footer (`--board`).
		 */
		padding: 6px max(10px, env(safe-area-inset-right))
			calc(10px + var(--safe-bottom, max(0px, env(safe-area-inset-bottom) - var(--board, 0px))))
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

	/* Every button of the row is 40px beside a 44px line: centred on the last line. */
	.compose > :global(button) {
		margin-bottom: 2px;
	}

	.compose > .send {
		margin-bottom: 0;
	}

	.send {
		position: relative;
		flex: none;
		display: inline-flex;
		align-items: center;
		justify-content: center;
		/* A full touch target, as tall as one line of the box beside it. */
		width: var(--hit);
		height: var(--hit);
		border-radius: 50%;
		background: var(--accent);
		color: #fff;
	}

	.cancel {
		position: relative;
		flex: none;
		height: 40px;
		padding: 0 14px;
		border-radius: 20px;
		background: var(--surface);
		border: 1px solid var(--border);
		font-size: 14px;
		white-space: nowrap;
	}

	/* A send on its way keeps its colour: dimmed like "off" it would read as broken. */
	.send[aria-busy='true']:disabled {
		opacity: 0.75;
	}

	/* The next tap cuts the turn short. The shape says so; the colour says it again. */
	.send.armed {
		background: var(--red);
	}

	/* Heard, not seen. */
	.said {
		position: absolute;
		width: 1px;
		height: 1px;
		overflow: hidden;
		clip-path: inset(50%);
		white-space: nowrap;
	}

	/* The sign that it is on its way. With reduced motion it is a still ring. */
	.busy {
		width: 16px;
		height: 16px;
		border-radius: 50%;
		border: 2px solid rgba(255, 255, 255, 0.4);
		border-top-color: #fff;
		animation: sending 0.8s linear infinite;
	}

	@keyframes sending {
		to {
			transform: rotate(360deg);
		}
	}
</style>
