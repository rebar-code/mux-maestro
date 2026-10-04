<script lang="ts">
	import { keepFocus } from './focus';
	import Icon from './Icon.svelte';
	import { live, OFF_LABEL } from './live.svelte';
	import { voice, type VoiceSink, type VoiceTarget } from './voice.svelte';

	/**
	 * The bar of one target: the manager, or a thread. `part` draws only the
	 * status line or only the controls, for a view that puts something between
	 * the two.
	 */
	const {
		target,
		sink,
		off = false,
		part = 'all'
	}: {
		target: VoiceTarget;
		sink: VoiceSink;
		/** Voice is switched off on the Mac: the bar says so and has no controls. */
		off?: boolean;
		part?: 'all' | 'status' | 'controls';
	} = $props();

	const status = $derived(voice.statusOf(target));
	/** The mic is open for this bar: a take, or Auto waiting for one. */
	const hearing = $derived(
		!off && !voice.micMuted && (status === 'recording' || (status === 'idle' && voice.listening))
	);
	/** The mic's loudness as the meter draws it, 0 to 1. Speech fills most of it. */
	const level = $derived(hearing ? Math.min(1, Math.sqrt(voice.level * 8)) : 0);
</script>

{#if off}
	<div class="vbar off" data-voicebar data-voice="off">
		<div class="vstat" role="status" data-voice-status>
			<span class="wave" aria-hidden="true"><i></i><i></i><i></i><i></i></span>
			<!-- Not before the Mac has answered: until then nothing is known to be off. -->
			{live.config === null ? '' : OFF_LABEL}
		</div>
	</div>
{:else if part === 'status'}
	<div class="vbar alone" data-voice-line>{@render line()}</div>
{:else}
	{@render controls()}
{/if}

{#snippet line()}
	<div class="vstat {status}" class:paused={voice.paused} role="status" data-voice-status>
		{#if hearing}
			<!-- The mic's level, so it is plain that the phone hears. -->
			<span
				class="wave meter"
				role="meter"
				aria-label="Mic level"
				aria-valuemin="0"
				aria-valuemax="100"
				aria-valuenow={Math.round(level * 100)}
				data-voice-level={Math.round(level * 100)}
				style:--level={level}><i></i><i></i><i></i><i></i></span
			>
		{:else}
			<span class="wave" aria-hidden="true"><i></i><i></i><i></i><i></i></span>
		{/if}
		{voice.note ?? voice.label(target)}
	</div>
{/snippet}

{#snippet controls()}
	<div
		class="vbar"
		class:bare={part === 'controls'}
		data-voicebar
		data-voice={status}
		data-first-text-ms={voice.timing.text}
		data-first-audio-ms={voice.timing.audio}
		{@attach voice.attach}
		{@attach keepFocus}
	>
		{#if part === 'all'}{@render line()}{/if}
		<div class="vrow">
			<div class="vseg" role="group" aria-label="Voice mode">
				<button
					class="grow"
					class:on={voice.mode === 'auto'}
					aria-pressed={voice.mode === 'auto'}
					onclick={() => voice.setMode('auto', target, sink)}>Auto</button
				>
				<button
					class="grow"
					class:on={voice.mode === 'manual'}
					aria-pressed={voice.mode === 'manual'}
					onclick={() => voice.setMode('manual', target, sink)}>Manual</button
				>
			</div>
			<button
				class="ip"
				class:off={!voice.speaker}
				aria-label="Speaker"
				aria-pressed={voice.speaker}
				onclick={() => voice.setSpeaker(!voice.speaker)}
				><Icon name={voice.speaker ? 'speaker' : 'speakerOff'} /></button
			>
			<!-- Both act on the reply that is read out, so they share one pill. -->
			<div class="pair" role="group" aria-label="Playback">
				<button
					aria-label="Replay"
					disabled={status === 'thinking' || status === 'recording'}
					onclick={() => voice.replay(target, sink)}><Icon name="replay" /></button
				>
				<button aria-label="Skip" disabled={status !== 'speaking'} onclick={voice.skip}
					><Icon name="skip" /></button
				>
			</div>
			<!-- Manual opens the mic only on a tap, so there is nothing to mute. -->
			{#if voice.mode === 'auto'}
				<button
					class="ip"
					class:off={voice.micMuted}
					aria-label="Microphone"
					aria-pressed={!voice.micMuted}
					onclick={() => voice.toggleMic(target, sink)}
					><Icon name={voice.micMuted ? 'micOff' : 'mic'} /></button
				>
			{/if}
		</div>
	</div>
{/snippet}

<style>
	.vbar {
		flex: none;
		padding: 7px max(12px, env(safe-area-inset-right)) 2px max(12px, env(safe-area-inset-left));
		border-top: 1px solid var(--border);
		background: var(--bar);
	}

	.vbar.off {
		padding-bottom: 0;
	}

	.vbar.off .vstat {
		padding-bottom: 2px;
	}

	/* The status line by itself, above the key bar. */
	.vbar.alone {
		padding-bottom: 0;
	}

	.vbar.alone .vstat {
		padding-bottom: 6px;
	}

	/* The controls by themselves: the line above them is drawn elsewhere. */
	.vbar.bare {
		border-top: 0;
		padding-top: 0;
	}

	.vstat {
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 0 2px 7px;
		font-size: 12.5px;
		color: var(--muted);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.vstat.recording,
	.vstat.speaking {
		color: var(--text);
	}

	.wave {
		flex: none;
		display: inline-flex;
		align-items: center;
		gap: 2px;
		height: 14px;
	}

	.wave i {
		width: 3px;
		height: 5px;
		border-radius: 2px;
		background: #666;
	}

	.recording .wave i {
		background: #0a84ff;
	}

	.speaking .wave i {
		background: var(--green);
	}

	.thinking .wave i {
		background: var(--purple);
	}

	.recording .wave i,
	.speaking:not(.paused) .wave i {
		animation: wave 0.5s ease-in-out infinite alternate;
	}

	/* The meter: each bar's height follows the mic, not a clock. */
	.vstat .meter i {
		animation: none;
		background: #0a84ff;
		height: calc(3px + 11px * var(--level));
		transition: height 0.08s linear;
	}

	.vstat .meter i:nth-child(2) {
		height: calc(3px + 8px * var(--level));
	}

	.vstat .meter i:nth-child(3) {
		height: calc(3px + 11px * var(--level));
	}

	.vstat .meter i:nth-child(1),
	.vstat .meter i:nth-child(4) {
		height: calc(3px + 5px * var(--level));
	}

	.wave i:nth-child(2) {
		animation-delay: 0.12s;
	}

	.wave i:nth-child(3) {
		animation-delay: 0.24s;
	}

	.wave i:nth-child(4) {
		animation-delay: 0.36s;
	}

	@keyframes wave {
		to {
			height: 14px;
		}
	}

	.vrow {
		display: flex;
		align-items: center;
		gap: 8px;
	}

	.vseg {
		display: flex;
		width: 136px;
		margin-right: auto;
		padding: 2px;
		border-radius: 9px;
		background: var(--surface);
	}

	.vseg button {
		position: relative;
		flex: 1;
		padding: 5px 0;
		border-radius: 7px;
		font-size: 12px;
		color: var(--muted);
	}

	.vseg button.on {
		background: #2a2a2a;
		color: var(--text);
	}

	/*
	 * The look is a 36pt circle; the touch area is 44pt and meets its
	 * neighbour's. The inset counts from inside the 1px border.
	 */
	.ip {
		position: relative;
		flex: none;
		display: inline-flex;
		align-items: center;
		justify-content: center;
		color: #cfcfcf;
		width: 36px;
		height: 36px;
		border-radius: 50%;
		background: var(--surface);
		border: 1px solid var(--border);
		font-size: 15px;
	}

	.ip::after {
		content: '';
		position: absolute;
		inset: -5px;
	}

	/* Two buttons in one oval, with a hairline between them. */
	.pair {
		flex: none;
		display: flex;
		height: 36px;
		border-radius: 18px;
		background: var(--surface);
		border: 1px solid var(--border);
	}

	.pair button {
		position: relative;
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 44px;
		color: #cfcfcf;
	}

	.pair button + button {
		border-left: 1px solid var(--border);
	}

	.pair button::after {
		content: '';
		position: absolute;
		inset: -5px 0;
	}

	.ip.off {
		background: #3a1512;
		border-color: #5a2320;
	}
</style>
