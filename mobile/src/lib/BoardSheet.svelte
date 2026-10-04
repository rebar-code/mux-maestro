<script lang="ts">
	import { untrack } from 'svelte';
	import BoardList from './BoardList.svelte';
	import { ui } from './gestures.svelte';
	import { sheetHeight, sheetStops } from './pager';

	const height = $derived(sheetHeight(ui.sheetHeights, ui.sheet, ui.sheetUp));

	/** Attachment: the stops follow the room the thread has for the footer to rise into. */
	function measure(node: HTMLElement): () => void {
		const view = node.parentElement ?? node;
		const fit = (): void => {
			const thread = view.querySelector<HTMLElement>('[data-thread-pages]');
			const foot = view.querySelector<HTMLElement>('[data-foot]');
			if (!thread || !foot) return;
			// From the top of the thread's pages down to where the footer rests.
			const top = thread.getBoundingClientRect().top - view.getBoundingClientRect().top;
			const room = view.clientHeight - top - foot.offsetHeight;
			untrack(() => (ui.sheetHeights = sheetStops(room, window.innerHeight)));
		};
		const observer = new ResizeObserver(fit);
		observer.observe(view);
		fit();
		return () => {
			observer.disconnect();
			untrack(() => (ui.sheet = 0));
		};
	}
</script>

<!--
	The board, below the footer. It has no height at rest: the footer is then at
	the bottom of the screen. As the footer rises, this is what shows under it.
-->
<section
	class="board"
	class:anim={!ui.sheetDragging}
	style:height="{height}px"
	aria-label="Board"
	inert={ui.sheet === 0}
	data-sheet
	data-sheet-list
	data-board
	data-stop={ui.sheet}
	{@attach measure}
>
	<BoardList />
</section>

<style>
	/* Scrolled by the gesture controller, and only at the tall stop. */
	.board {
		flex: none;
		overflow: hidden;
		background: var(--mgr);
	}

	/* A little past its target and back: the drawer lands like a spring. */
	.board.anim {
		transition: height 0.36s cubic-bezier(0.2, 1.25, 0.35, 1);
	}

	/*
	 * Every drag on the board is ours: up and down move the drawer or scroll
	 * the list, sideways swipes a card away or opens the sidebar.
	 */
	.board,
	.board :global(*) {
		touch-action: none;
	}
</style>
