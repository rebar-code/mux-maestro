<script lang="ts">
	import { can, live, OFF_LABEL } from './live.svelte';
	import { maestro } from './maestro.svelte';
	import { needsYouCards } from './manager';
	import { manager } from './manager.svelte';
	import { maestroState, needCount, pointCards } from './panel';

	/**
	 * The Maestro button: drawn once by the layout, over the header of every
	 * page and at the same place on each. It opens the Maestro's screen, and on
	 * that screen it is the X that goes back. It shows at a glance what the
	 * Maestro does and how many sessions need the user.
	 */
	const on = $derived(can('manager'));
	const state = $derived(maestroState({ on, busy: manager.busy, status: manager.status }));
	const needs = $derived(
		on
			? needCount(
					needsYouCards(live.threads ?? [], manager.needsYou),
					pointCards(manager.points, live.threads)
				)
			: 0
	);
	const LABELS = { off: OFF_LABEL, asks: 'asks you', working: 'working', idle: 'idle' };
	const label = $derived(
		maestro.open
			? 'Close the Maestro'
			: `Maestro, ${LABELS[state]}${needs ? `, ${needs} need you` : ''}`
	);
</script>

<!-- With the Maestro switched on it is kept current on every page, not only on its own. -->
<button
	class="mb"
	class:pulse={maestro.jumped}
	aria-label={label}
	aria-disabled={!on}
	title={on ? undefined : OFF_LABEL}
	data-maestro
	data-open={maestro.open ? '' : undefined}
	data-state={state}
	onclick={maestro.toggle}
	{@attach on && manager.watch}
>
	<span class="ring" aria-hidden="true"></span>
	<span class="mark" aria-hidden="true">{maestro.open ? '✕' : '✦'}</span>
	{#if state === 'asks'}<i class="ask" aria-hidden="true"></i>{/if}
	{#if needs}<span class="count" data-count>{needs}</span>{/if}
</button>

<style>
	.mb {
		position: absolute;
		top: env(safe-area-inset-top);
		right: max(3px, env(safe-area-inset-right));
		/* Over the page's header, under the sidebar and its scrim. */
		z-index: 35;
		width: var(--hit);
		height: var(--hit);
		display: flex;
		align-items: center;
		justify-content: center;
		border-radius: 50%;
		color: var(--purple);
		font-size: 17px;
	}

	.mb:active {
		filter: brightness(1.35);
	}

	.mb[aria-disabled='true'] {
		color: #5c5c6b;
	}

	.mb[data-open] .ring {
		background: #2a2440;
	}

	.ring {
		position: absolute;
		inset: 6px;
		border-radius: 50%;
		border: 1.5px solid #3a3350;
		background: #1c1a2a;
	}

	.mb[aria-disabled='true'] .ring {
		border-color: #2a2a33;
		background: none;
	}

	/* Working: the ring turns. */
	.mb[data-state='working'] .ring {
		border-color: #3a3350;
		border-top-color: var(--purple);
		animation: turn 0.9s linear infinite;
	}

	.mb[data-state='asks'] .ring {
		border-color: var(--red);
	}

	.mark {
		position: relative;
		line-height: 1;
	}

	/* The Maestro waits on a question of its own. */
	.ask {
		position: absolute;
		left: 5px;
		top: 6px;
		width: 9px;
		height: 9px;
		border-radius: 50%;
		background: var(--red);
		border: 1.5px solid var(--bar);
		animation: pulse 1.6s infinite;
	}

	.count {
		position: absolute;
		right: 1px;
		top: 3px;
		min-width: 16px;
		height: 16px;
		padding: 0 4px;
		border-radius: 8px;
		background: var(--red);
		color: #fff;
		font-size: 10.5px;
		font-weight: 600;
		line-height: 16px;
		text-align: center;
	}

	/* After a jump: the way back shows itself once. */
	.pulse .ring {
		animation: back 0.9s ease-out 1;
	}

	@keyframes turn {
		to {
			transform: rotate(360deg);
		}
	}

	@keyframes back {
		0% {
			box-shadow: 0 0 0 0 rgba(163, 113, 247, 0.7);
		}

		100% {
			box-shadow: 0 0 0 14px rgba(163, 113, 247, 0);
		}
	}
</style>
