<script lang="ts">
	import '../app.css';
	import Drawer from '$lib/Drawer.svelte';
	import { gestures, ui } from '$lib/gestures.svelte';
	import { connect, live } from '$lib/live.svelte';
	import { keyboardInset } from '$lib/pager';
	import Pair from '$lib/Pair.svelte';

	const { children } = $props();

	/**
	 * Attachment for the app root: while the on-screen keyboard is open the page
	 * is as tall as what is left above it, so the last row sits on the keyboard.
	 * The keyboard does not shrink the page by itself on a phone.
	 */
	function keyboard(node: HTMLElement): (() => void) | void {
		const visible = window.visualViewport;
		if (!visible) return;
		const fit = (): void => {
			const inset = keyboardInset(document.documentElement.clientHeight, visible.height);
			node.style.setProperty('--keyboard', `${inset}px`);
			// The browser scrolls the page to show the box; the shorter page already does.
			if (inset) window.scrollTo(0, 0);
		};
		visible.addEventListener('resize', fit);
		return () => visible.removeEventListener('resize', fit);
	}
</script>

<div class="app" {@attach gestures} {@attach connect} {@attach keyboard}>
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
		height: calc(100% - var(--keyboard, 0px));
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
