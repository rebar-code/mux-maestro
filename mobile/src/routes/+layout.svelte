<script lang="ts">
	import '../app.css';
	import { afterNavigate } from '$app/navigation';
	import ActionSheet from '$lib/ActionSheet.svelte';
	import Drawer from '$lib/Drawer.svelte';
	import { gestures, ui } from '$lib/gestures.svelte';
	import { connect, live } from '$lib/live.svelte';
	import { maestro } from '$lib/maestro.svelte';
	import MaestroButton from '$lib/MaestroButton.svelte';
	import { keyboardInset } from '$lib/pager';
	import Pair from '$lib/Pair.svelte';
	import { notifications } from '$lib/push.svelte';
	import { keepDrafts } from '$lib/drafts';
	import { freshBuild } from '$lib/update';

	const { children } = $props();

	// The Maestro button knows the page its screen was opened from.
	afterNavigate(maestro.arrived);

	/**
	 * Attachment for the app root: while the on-screen keyboard is open the page
	 * is exactly what is left above it, so the last row sits on the keyboard.
	 * The keyboard does not shrink the page by itself on a phone; it shrinks the
	 * visual viewport, and iOS may also slide that viewport down the page to
	 * show the focused box. The page follows both: its height and its top.
	 */
	function keyboard(node: HTMLElement): (() => void) | void {
		const visible = window.visualViewport;
		if (!visible) return;
		const fit = (): void => {
			const inset = keyboardInset(document.documentElement.clientHeight, visible.height);
			node.style.setProperty('--keyboard', `${inset}px`);
			node.toggleAttribute('data-kb', inset > 0);
			// No home indicator under the last row while the keyboard covers it.
			if (inset) node.style.setProperty('--safe-bottom', '0px');
			else node.style.removeProperty('--safe-bottom');
			// A page the browser scrolled goes back; what it slid instead is followed.
			if (inset && window.scrollY > 0) window.scrollTo(0, 0);
			node.style.setProperty('--slid', `${inset ? Math.max(0, visible.offsetTop) : 0}px`);
		};
		fit();
		visible.addEventListener('resize', fit);
		visible.addEventListener('scroll', fit);
		return () => {
			visible.removeEventListener('resize', fit);
			visible.removeEventListener('scroll', fit);
		};
	}
</script>

<div
	class="app"
	data-app
	{@attach gestures}
	{@attach connect}
	{@attach keyboard}
	{@attach notifications}
	{@attach freshBuild}
	{@attach keepDrafts}
>
	{#if live.unpaired}
		<Pair />
	{:else if live.forbidden}
		<div class="denied" role="alert">Not allowed</div>
	{:else}
		<div class="view" inert={ui.drawerOpen}>
			{@render children()}
		</div>
		<MaestroButton />
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
		<ActionSheet />
	{/if}
</div>

<style>
	.app {
		position: relative;
		max-width: 430px;
		top: var(--slid, 0px);
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
