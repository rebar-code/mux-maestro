<script lang="ts">
	import { live, OFF_LABEL } from './live.svelte';
	import { voice, type VoiceSink, type VoiceTarget } from './voice.svelte';

	/** The bar of one target: the manager, or a thread. */
	const {
		target,
		sink,
		off = false
	}: {
		target: VoiceTarget;
		sink: VoiceSink;
		/** Voice is switched off on the Mac: the bar says so and has no controls. */
		off?: boolean;
	} = $props();

	const status = $derived(voice.statusOf(target));
</script>

{#if off}
	<div class="vbar off" data-voicebar data-voice="off">
		<div class="vstat" role="status" data-voice-status>
			<span class="wave" aria-hidden="true"><i></i><i></i><i></i><i></i></span>
			<!-- Not before the Mac has answered: until then nothing is known to be off. -->
			{live.config === null ? '' : OFF_LABEL}
		</div>
	</div>
{:else}
	{@render controls()}
{/if}

{#snippet controls()}
	<div class="vbar" data-voicebar data-voice={status} {@attach voice.attach}>
		<div class="vstat {status}" class:paused={voice.paused} role="status" data-voice-status>
			<span class="wave" aria-hidden="true"><i></i><i></i><i></i><i></i></span>
			{voice.note ?? voice.label(target)}
		</div>
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
				onclick={() => voice.setSpeaker(!voice.speaker)}>{voice.speaker ? '🔊' : '🔇'}</button
			>
			<button
				class="ip"
				aria-label="Replay"
				disabled={status === 'thinking' || status === 'recording'}
				onclick={() => voice.replay(target, sink)}>↻</button
			>
			<button class="ip" aria-label="Skip" disabled={status !== 'speaking'} onclick={voice.skip}
				>⏭</button
			>
			<button
				class="ip"
				class:off={voice.micMuted}
				aria-label="Microphone"
				aria-pressed={!voice.micMuted}
				onclick={() => voice.toggleMic(target, sink)}>🎙</button
			>
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

	.ip.off {
		background: #3a1512;
		border-color: #5a2320;
	}
</style>
