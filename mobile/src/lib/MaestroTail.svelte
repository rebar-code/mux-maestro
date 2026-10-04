<script lang="ts">
	import ActionCard from './ActionCard.svelte';
	import { live } from './live.svelte';
	import { thinkingText } from './manager';
	import { manager } from './manager.svelte';
	import { pointCards } from './panel';

	/**
	 * After the last row of the Maestro's chat: the questions it passes on for
	 * an answer, and what it is doing now.
	 */
	const { onterminal }: { onterminal: () => void } = $props();

	const asked = $derived(
		pointCards(manager.points, live.threads).filter((point) => point.card !== null)
	);

	/** Ticks while a turn runs, for the time beside the dots. */
	let now = $state(Date.now());
	const seconds = $derived(Math.max(0, Math.floor((now - manager.turnSince) / 1000)));

	/** Attachment for the thinking line: a clock, for as long as the line is drawn. */
	function clock(): () => void {
		now = Date.now();
		const timer = setInterval(() => (now = Date.now()), 1000);
		return () => clearInterval(timer);
	}
</script>

{#each asked as point (point.key)}
	<ActionCard {point} />
{/each}
{#if manager.busy}
	<div class="think" role="status" data-thinking {@attach clock}>
		<span class="dots" aria-hidden="true"><i></i><i></i><i></i></span>
		<span data-thinking-text>{thinkingText(manager.spinner, seconds)}</span>
	</div>
{/if}
{#if manager.note ?? manager.statusNote}
	<div class="state">
		{#if manager.note}
			<span class="note" role="alert">{manager.note}</span>
		{:else}
			<span class="note quiet" role="status" data-status={manager.status}>{manager.statusNote}</span
			>
		{/if}
		{#if manager.status === 'waiting'}
			<!-- The prompt is answered in the pane: the terminal shows it. -->
			<button class="chip grow" onclick={onterminal}>Terminal</button>
		{/if}
	</div>
{/if}

<style>
	.note {
		align-self: center;
		font-size: 12.5px;
		color: var(--red);
		background: #1f1110;
		border: 1px solid #5a2320;
		border-radius: 8px;
		padding: 4px 10px;
	}

	.note.quiet {
		color: var(--muted);
		background: var(--surface);
		border-color: var(--border);
	}

	.think {
		display: flex;
		align-items: center;
		gap: 9px;
		font-size: 13px;
		color: #b9b9d0;
	}

	.dots {
		display: inline-flex;
		gap: 4px;
	}

	.dots i {
		width: 6px;
		height: 6px;
		border-radius: 50%;
		background: var(--purple);
		animation: think 1s ease-in-out infinite alternate;
	}

	.dots i:nth-child(2) {
		animation-delay: 0.2s;
	}

	.dots i:nth-child(3) {
		animation-delay: 0.4s;
	}

	@keyframes think {
		from {
			opacity: 0.25;
		}
	}

	.state {
		display: flex;
		align-items: center;
		gap: 8px;
	}
</style>
