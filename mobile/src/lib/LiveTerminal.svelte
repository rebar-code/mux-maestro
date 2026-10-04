<script lang="ts">
	import '@xterm/xterm/css/xterm.css';
	import type { LiveTerm } from './liveterm.svelte';
	import { text } from './textsize.svelte';

	/** The pane itself, live. Hidden until its first screen came. */
	const { term }: { term: LiveTerm } = $props();
</script>

<div
	class="scroll live"
	class:shown={term.shown}
	data-view="live"
	data-state={term.state}
	data-zoom
	{@attach term.mount}
	{@attach term.sized(text.size)}
>
	<div class="box" data-box>
		<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
		<div class="pin" data-pin data-hscroll onclick={term.focus}>
			<div class="host" data-term></div>
		</div>
	</div>
</div>

<style>
	/* Laid out, so the terminal can measure its text, and not seen. */
	.live {
		position: absolute;
		inset: 0;
		visibility: hidden;
		overflow-anchor: none;
		background: var(--bg);
	}

	.live.shown {
		position: static;
		visibility: visible;
	}

	/* The view onto the terminal: it stays put while the box scrolls under it. */
	.pin {
		position: sticky;
		top: 0;
		/* Moved sideways by the gesture controller, like the captured view. */
		overflow: hidden;
	}

	/* Touches are the page's: the terminal's own scrolling never sees them. */
	.host {
		width: max-content;
		padding: 0 12px;
		pointer-events: none;
		will-change: transform;
	}

	/* Below 16px, iOS zooms the page when the box takes focus. */
	.host :global(.xterm-helper-textarea) {
		font-size: 16px;
	}

	.host :global(.xterm-scrollable-element > .scrollbar) {
		display: none;
	}
</style>
