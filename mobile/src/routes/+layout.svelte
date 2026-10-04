<script lang="ts">
	import '../app.css';
	import Drawer from '$lib/Drawer.svelte';
	import { gestures, ui } from '$lib/gestures.svelte';
	import { connect, live } from '$lib/live.svelte';
	import Pair from '$lib/Pair.svelte';

	const { children } = $props();
</script>

<div class="app" {@attach gestures} {@attach connect}>
	{#if live.unpaired}
		<Pair />
	{:else if live.forbidden}
		<div class="denied" role="alert">Not allowed</div>
	{:else}
		<div class="view" inert={ui.drawerOpen}>
			{@render children()}
		</div>
		<button
			class="scrim"
			class:anim={!ui.dragging}
			class:shown={ui.drawer > 0 && !ui.dragging}
			style:opacity={ui.drawer}
			aria-label="Close sidebar"
			tabindex={ui.drawerOpen ? 0 : -1}
			onclick={() => ui.closeDrawer()}
		></button>
		<Drawer />
	{/if}
</div>

<style>
	.app {
		position: relative;
		max-width: 430px;
		height: 100%;
		margin: 0 auto;
		background: var(--bg);
		overflow: hidden;
	}

	/*
	 * Vertical scrolling stays the browser's; sideways drags are ours. Set on
	 * every element, because a scroller in between would otherwise reset it and
	 * the browser would take the sideways drag (and cancel the pointer).
	 */
	.app,
	.app :global(*) {
		touch-action: pan-y;
	}

	.view {
		display: flex;
		flex-direction: column;
		height: 100%;
	}

	.scrim {
		position: absolute;
		inset: 0;
		z-index: 40;
		width: 100%;
		background: rgba(0, 0, 0, 0.55);
		pointer-events: none;
		border-radius: 0;
	}

	.scrim.shown {
		pointer-events: auto;
	}

	.scrim.anim {
		transition: opacity 0.24s var(--ease);
	}

	.denied {
		display: flex;
		align-items: center;
		justify-content: center;
		height: 100%;
		color: var(--muted);
		font-size: 17px;
	}
</style>
