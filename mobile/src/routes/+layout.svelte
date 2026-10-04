<script lang="ts">
	import '../app.css';
	import { afterNavigate } from '$app/navigation';
	import ActionSheet from '$lib/ActionSheet.svelte';
	import Drawer from '$lib/Drawer.svelte';
	import { gestures, ui } from '$lib/gestures.svelte';
	import { can, connect, live } from '$lib/live.svelte';
	import { maestro } from '$lib/maestro.svelte';
	import MaestroButton from '$lib/MaestroButton.svelte';
	import MaestroPanel from '$lib/MaestroPanel.svelte';
	import { pageFit } from '$lib/pager';
	import Pair from '$lib/Pair.svelte';
	import { notifications } from '$lib/push.svelte';
	import { keepDrafts } from '$lib/drafts';
	import { freshBuild } from '$lib/update';

	const { children } = $props();

	// Back to the page a jump left from opens the Maestro panel there again.
	afterNavigate((navigation) => maestro.arrived(navigation.type, location.pathname));

	/**
	 * Attachment for the app root: it fills the screen, and while the on-screen
	 * keyboard is open the page is exactly what is left above it, so the last
	 * row sits on the keyboard. The keyboard does not shrink the page by itself
	 * on a phone; it shrinks the visual viewport, and iOS may also slide that
	 * viewport down the page to show the focused box. The page follows both: its
	 * height and its top. `pageFit` has the rule.
	 */
	function keyboard(node: HTMLElement): (() => void) | void {
		const visible = window.visualViewport;
		if (!visible) return;
		const root = document.documentElement;
		const standalone =
			window.matchMedia('(display-mode: standalone)').matches ||
			(navigator as { standalone?: boolean }).standalone === true;
		let lift = 0;
		const fit = (): void => {
			const sides = [window.screen.width, window.screen.height];
			const fitted = pageFit({
				// What the browser gave the page, without what was added here.
				layout: root.getBoundingClientRect().height - lift,
				visible: visible.height,
				slid: visible.offsetTop,
				// A screen on its side: some browsers still name its sides as upright.
				screen: window.innerWidth > window.innerHeight ? Math.min(...sides) : Math.max(...sides),
				standalone,
				safeTop: node.querySelector<HTMLElement>('[data-inset]')?.offsetHeight ?? 0
			});
			const inset = fitted.keyboard;
			lift = fitted.lift;
			// The band under the last row was here: the page was one status bar short.
			root.style.setProperty('--lift', `${lift}px`);
			node.style.setProperty('--keyboard', `${inset}px`);
			node.toggleAttribute('data-kb', inset > 0);
			// No home indicator under the last row while the keyboard covers it.
			if (inset) node.style.setProperty('--safe-bottom', '0px');
			else node.style.removeProperty('--safe-bottom');
			// A page the browser scrolled goes back; what it slid instead is followed.
			if (inset && window.scrollY > 0) window.scrollTo(0, 0);
			node.style.setProperty('--slid', `${fitted.slid}px`);
		};
		fit();
		visible.addEventListener('resize', fit);
		visible.addEventListener('scroll', fit);
		return () => {
			visible.removeEventListener('resize', fit);
			visible.removeEventListener('scroll', fit);
			root.style.removeProperty('--lift');
		};
	}
</script>

<div
	class="app"
	data-app
	{@attach gestures}
	{@attach maestro.drag}
	{@attach connect}
	{@attach keyboard}
	{@attach notifications}
	{@attach freshBuild}
	{@attach keepDrafts}
>
	<i class="inset" data-inset aria-hidden="true"></i>
	{#if live.unpaired}
		<Pair />
	{:else if live.forbidden}
		<div class="denied" role="alert">Not allowed</div>
	{:else}
		<div class="view" inert={ui.drawerOpen || maestro.stop >= 2}>
			{@render children()}
		</div>
		{#if can('manager')}<MaestroPanel />{/if}
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

	/* The drags that move the Maestro panel begin on these: none of them scrolls. */
	.app :global([data-maestro-grab]),
	.app :global([data-maestro-grab] *) {
		touch-action: none;
	}

	/* As tall as the status bar's inset, for `keyboard` to read; it shows nothing. */
	.inset {
		position: absolute;
		top: 0;
		left: 0;
		width: 0;
		height: env(safe-area-inset-top);
		visibility: hidden;
		pointer-events: none;
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
