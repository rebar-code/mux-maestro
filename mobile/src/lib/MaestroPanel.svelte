<script lang="ts">
	import BoardList from './BoardList.svelte';
	import { live } from './live.svelte';
	import { maestro } from './maestro.svelte';
	import MaestroInput from './MaestroInput.svelte';
	import MaestroTail from './MaestroTail.svelte';
	import { boardSummary, needsYouCards } from './manager';
	import { manager } from './manager.svelte';
	import { maestroState, needCount, pointCards } from './panel';
	import ThreadView from './ThreadView.svelte';

	/**
	 * The Maestro panel: it drops from the top edge over the page that is open
	 * and takes the header's place. The peek shows the end of the Maestro's chat
	 * and its text box; the half stop shows more of the chat; the full stop adds
	 * the board. The page under it is not unmounted: its scroll and its draft stay.
	 */
	const STOPS = ['closed', 'peek', 'half', 'full'] as const;
	const STATES = { off: '', asks: 'Asks you', working: 'Working', idle: '' };

	const state = $derived(maestroState({ on: true, busy: manager.busy, status: manager.status }));
	const summary = $derived(
		boardSummary({
			needsYou: needCount(
				needsYouCards(live.threads ?? [], manager.needsYou),
				pointCards(manager.points, live.threads)
			),
			review: manager.review?.length ?? 0,
			updates: Math.min(manager.updates.length, 5)
		})
	);

	function ended(event: TransitionEvent): void {
		if (event.target === event.currentTarget && event.propertyName === 'height') maestro.settled();
	}
</script>

{#snippet none()}{/snippet}
{#snippet tail()}
	<MaestroTail onterminal={() => (maestro.terminal = true)} />
{/snippet}

<button
	class="veil"
	class:shown={maestro.stop >= 2}
	aria-label="Close the Maestro panel"
	tabindex="-1"
	data-maestro-panel
	onclick={maestro.close}
></button>
<section
	class="panel"
	class:anim={!maestro.dragging}
	style:height="{maestro.height}px"
	aria-label="Maestro"
	inert={!maestro.open}
	data-maestro-panel
	data-panel
	data-stop={maestro.stop}
	ontransitionend={ended}
	{@attach maestro.measure}
>
	{#if maestro.shown}
		<div class="head" data-maestro-grab data-panel-chrome>
			<b>Maestro</b>
			{#if STATES[state]}<span data-panel-state>{STATES[state]}</span>{/if}
		</div>
		<div class="chat" class:peek={maestro.stop === 1 && !maestro.dragging}>
			<ThreadView
				id="manager"
				feed={manager.feed}
				header={none}
				{tail}
				pending={manager.pending}
				reply={maestro.reply}
				embedded
				bind:terminal={maestro.terminal}
			/>
		</div>
		<div class="input" data-panel-chrome data-panel-input>
			<MaestroInput />
		</div>
		{#if maestro.stop === 3}
			<div class="board" data-panel-board>
				<BoardList />
			</div>
		{/if}
		<button
			class="grab"
			aria-label="Maestro panel, {STOPS[maestro.stop]}, {summary}"
			data-maestro-grab
			data-panel-chrome
			data-panel-grab
			onclick={maestro.step}
		>
			<span class="sum">{summary}</span>
			<span class="bar"></span>
		</button>
	{/if}
</section>

<style>
	.veil {
		position: absolute;
		inset: 0;
		z-index: 29;
		width: 100%;
		border-radius: 0;
		background: rgba(0, 0, 0, 0.5);
		opacity: 0;
		pointer-events: none;
		transition: opacity 0.24s var(--ease);
	}

	.veil.shown {
		opacity: 1;
		pointer-events: auto;
	}

	.panel {
		position: absolute;
		top: 0;
		left: 0;
		right: 0;
		z-index: 30;
		max-height: 100%;
		display: flex;
		flex-direction: column;
		/* What does not fit is cut at the top: the text box and the grabber come down first. */
		justify-content: flex-end;
		overflow: hidden;
		background: var(--mgr);
		border-radius: 0 0 16px 16px;
		box-shadow: 0 10px 30px rgba(0, 0, 0, 0.55);
		/* The panel is at the top of the screen: nothing in it clears the home indicator. */
		--safe-bottom: 0px;
		--below: 0px;
	}

	/* A little past its target and back: the panel lands like a spring. */
	.panel.anim {
		transition: height 0.36s cubic-bezier(0.2, 1.25, 0.35, 1);
	}

	.head {
		flex: none;
		display: flex;
		align-items: baseline;
		gap: 8px;
		/* The button is drawn over the right end. */
		padding: calc(env(safe-area-inset-top) + 12px) 56px 0 max(16px, env(safe-area-inset-left));
		height: calc(var(--hit) + env(safe-area-inset-top));
		font-size: 15px;
	}

	.head span {
		font-size: 12px;
		color: var(--muted);
	}

	.chat {
		flex: 1;
		min-height: 0;
		display: flex;
		flex-direction: column;
		overflow: hidden;
	}

	/* The peek is the end of the chat and the text box: the tabs come with the next stop. */
	.chat.peek :global(.tabs) {
		display: none;
	}

	.input {
		flex: none;
		background: var(--bar);
		border-top: 1px solid var(--border);
	}

	.input :global(.vbar) {
		padding-top: 3px;
		border-top: 0;
		background: none;
	}

	.input :global(.compose) {
		padding-top: 8px;
	}

	.board {
		flex: 0 1 auto;
		max-height: 36%;
		overflow-y: auto;
		overscroll-behavior: contain;
		border-top: 1px solid var(--border);
	}

	/* With the keyboard open the text box sits on it and the board stays shut. */
	:global([data-kb]) .board {
		display: none;
	}

	.grab {
		flex: none;
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		gap: 4px;
		width: 100%;
		height: 30px;
		position: relative;
		background: var(--bar);
		border-radius: 0;
	}

	/* 44pt of touch area on a 30pt strip, reaching down over the page's edge. */
	.grab::after {
		content: '';
		position: absolute;
		left: 0;
		right: 0;
		top: 0;
		height: var(--hit);
	}

	.bar {
		width: 36px;
		height: 4px;
		border-radius: 2px;
		background: #4a4a5e;
	}

	.sum {
		font-size: 11.5px;
		line-height: 1.2;
		color: var(--muted);
	}
</style>
