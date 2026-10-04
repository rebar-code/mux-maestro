<script lang="ts">
	import { voice, type PrimaryKind, type VoiceSink, type VoiceTarget } from './voice.svelte';

	/**
	 * The primary voice control of one target. `pill` sits beside the text box;
	 * `orb` is the large button of the manager home. Both do the same thing.
	 */
	const {
		target,
		sink,
		orb = false
	}: { target: VoiceTarget; sink: VoiceSink; orb?: boolean } = $props();

	const FACE: Record<PrimaryKind, { icon: string; label: string }> = {
		talk: { icon: '🎙', label: 'Talk' },
		submit: { icon: '↑', label: 'Submit' },
		stop: { icon: '■', label: 'Stop' },
		pause: { icon: '❚❚', label: 'Pause' },
		resume: { icon: '▶', label: 'Resume' }
	};

	const kind = $derived(voice.primaryOf(target));
	const face = $derived(FACE[kind]);
	const status = $derived(voice.statusOf(target));
	const disabled = $derived(kind === 'talk' && voice.micMuted);
</script>

{#if orb}
	<button
		class="orb {status}"
		class:paused={voice.paused}
		type="button"
		{disabled}
		aria-label={kind === 'talk' || kind === 'submit' ? `${face.label} to the Maestro` : face.label}
		data-orb
		onclick={() => voice.primary(target, sink)}
	>
		<span class="icon {kind}">{face.icon}</span>
	</button>
{:else}
	<button
		class="pill grow {status}"
		type="button"
		{disabled}
		data-primary={kind}
		onclick={() => voice.primary(target, sink)}
		><span class="icon {kind}">{face.icon}</span> {face.label}</button
	>
{/if}

<style>
	.pill {
		position: relative;
		flex: none;
		height: 40px;
		padding: 0 16px;
		border-radius: 20px;
		background: #fff;
		color: #000;
		font-weight: 600;
		font-size: 14px;
		white-space: nowrap;
		/* As wide as its longest label, so the text box beside it never moves. */
		min-width: 104px;
	}

	/* The two bars of the pause glyph, told apart. */
	.icon.pause {
		letter-spacing: 0.12em;
	}

	.pill.recording {
		background: #ff453a;
		color: #fff;
	}

	.pill.thinking,
	.pill.speaking {
		background: #3a3a3c;
		color: #fff;
	}

	.orb {
		width: 148px;
		height: 148px;
		border-radius: 50%;
		background: radial-gradient(circle at 35% 30%, #b99cff, #6b3fd6);
		box-shadow: 0 10px 50px rgba(163, 113, 247, 0.45);
		font-size: 52px;
		color: #fff;
	}

	.orb span {
		display: block;
	}

	.orb.recording {
		background: radial-gradient(circle at 35% 30%, #ff9a94, #c9302a);
		box-shadow: 0 10px 50px rgba(248, 81, 73, 0.45);
		animation: breathe 1.1s ease-in-out infinite;
	}

	.orb.thinking {
		background: radial-gradient(circle at 35% 30%, #8a8a96, #3a3a46);
		box-shadow: none;
	}

	.orb.speaking {
		background: radial-gradient(circle at 35% 30%, #8fe9b6, #1f9b5b);
		box-shadow: 0 10px 50px rgba(69, 212, 131, 0.4);
		animation: breathe 0.6s ease-in-out infinite;
	}

	.orb.speaking.paused {
		animation: none;
	}

	.orb:disabled {
		opacity: 0.28;
		filter: grayscale(0.6);
		box-shadow: none;
	}

	@keyframes breathe {
		50% {
			transform: scale(1.12);
		}
	}
</style>
