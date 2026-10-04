<script lang="ts">
	import { untrack } from 'svelte';
	import { resolve } from '$app/paths';
	import { age } from './format';
	import { swipeAway, ui } from './gestures.svelte';
	import { live } from './live.svelte';
	import { needsYouCards } from './manager';
	import { manager } from './manager.svelte';
	import { sheetHeight, sheetStops } from './pager';

	/** How many of the manager's updates the board lists. */
	const UPDATES = 5;

	const waiting = $derived(needsYouCards(live.threads ?? [], manager.needsYou));
	const review = $derived(manager.review);
	const updates = $derived(manager.updates.slice(0, UPDATES));
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
	<div class="in">
		{#if waiting.length}
			<div class="sect">Needs you · {waiting.length}</div>
			{#each waiting as { thread, why } (thread.id)}
				<a class="item" href={resolve('/t/[id]', { id: thread.id })} data-thread={thread.id}>
					<span class="sev blocked"></span>
					<span class="body">
						<b>{thread.session} · {thread.name}</b>
						<span
							>{why ?? 'needs you'} · {age(thread.since ?? thread.lastPrompt?.at, live.now)}</span
						>
					</span>
				</a>
			{/each}
		{/if}

		{#if review === null}
			<div class="sect">Review</div>
			<div class="skcard skel" aria-hidden="true"></div>
		{:else if review.length}
			<div class="sect">Review · {review.length}</div>
			{#each review as item (item.key)}
				{@const thread = item.thread ? live.byId(item.thread) : undefined}
				{@const key = item.key ?? ''}
				<div class="item" data-review={key} {@attach swipeAway(() => void manager.dismiss(key))}>
					<svelte:element
						this={thread ? 'a' : 'div'}
						class="open"
						href={thread ? resolve('/t/[id]', { id: thread.id }) : undefined}
					>
						<span class="sev {item.severity ?? 'info'}"></span>
						<span class="body">
							<b>{thread ? `${thread.session} · ${thread.name}` : item.title}</b>
							<span>{item.detail}</span>
						</span>
					</svelte:element>
					<button
						class="tb done"
						aria-label="Dismiss {thread ? `${thread.session} · ${thread.name}` : item.title}"
						onclick={() => manager.dismiss(key)}>✓</button
					>
				</div>
			{/each}
		{/if}

		{#if updates.length}
			<div class="sect">Updates</div>
			{#each updates as update, index (index)}
				{@const thread = update.thread ? live.byId(update.thread) : undefined}
				<svelte:element
					this={thread ? 'a' : 'div'}
					class="upd"
					class:grow={thread !== undefined}
					href={thread ? resolve('/t/[id]', { id: thread.id }) : undefined}
					data-update
				>
					<span class="what">
						{#if thread}<b>{thread.session} · {thread.name}</b>{/if}
						{update.text}
					</span>
					<span class="when">{age(update.at, live.now)}</span>
				</svelte:element>
			{/each}
		{/if}
		<div class="end"></div>
	</div>
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

	.in {
		padding-top: 4px;
	}

	.item {
		display: flex;
		gap: 10px;
		margin: 0 14px 8px;
		padding: 11px 12px;
		border-radius: 12px;
		background: #1c1c28;
		border: 1px solid #2b2b3d;
		text-align: left;
		transition: transform 0.2s var(--ease);
	}

	.item:active {
		filter: brightness(1.3);
	}

	.open {
		flex: 1;
		min-width: 0;
		display: flex;
		gap: 10px;
	}

	.sev {
		flex: none;
		width: 4px;
		border-radius: 2px;
		background: var(--accent);
	}

	.sev.warn {
		background: var(--amber);
	}

	.sev.blocked {
		background: var(--red);
	}

	.body {
		min-width: 0;
		font-size: 13px;
	}

	.item b {
		display: block;
		font-size: 14px;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.item .body span {
		font-size: 13px;
		color: var(--muted);
	}

	/* A 44pt touch area that does not make the card taller. */
	.done {
		align-self: center;
		margin: -8px -8px -8px 0;
		color: var(--muted);
	}

	.skcard {
		height: 62px;
		margin: 0 14px 8px;
		border-radius: 12px;
	}

	.upd {
		position: relative;
		display: flex;
		align-items: baseline;
		gap: 10px;
		margin: 0 14px;
		padding: 7px 2px;
		border-bottom: 1px solid #22222e;
		font-size: 13px;
		color: var(--muted);
	}

	.what {
		flex: 1;
		min-width: 0;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.what b {
		color: var(--text);
		font-weight: 600;
		margin-right: 4px;
	}

	.when {
		flex: none;
		font-size: 12px;
	}

	/* The board is the last thing on screen when it shows: it clears the home indicator. */
	.end {
		height: calc(16px + env(safe-area-inset-bottom));
	}
</style>
