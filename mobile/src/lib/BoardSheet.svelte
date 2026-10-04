<script lang="ts">
	import { untrack } from 'svelte';
	import { resolve } from '$app/paths';
	import { age } from './format';
	import { swipeAway, ui } from './gestures.svelte';
	import { live } from './live.svelte';
	import { boardSummary, needsYouCards } from './manager';
	import { manager } from './manager.svelte';
	import { sheetHeight, sheetStops } from './pager';

	/** How many of the manager's updates the board lists. */
	const UPDATES = 5;
	const STOPS = ['closed', 'open', 'full'] as const;

	const waiting = $derived(needsYouCards(live.threads ?? [], manager.needsYou));
	const review = $derived(manager.review);
	const updates = $derived(manager.updates.slice(0, UPDATES));
	const summary = $derived(
		boardSummary({
			needsYou: waiting.length,
			review: review?.length ?? 0,
			updates: updates.length
		})
	);
	const tall = $derived(ui.sheetHeights[2]);
	const height = $derived(sheetHeight(ui.sheetHeights, ui.sheet, ui.sheetUp));

	/** Attachment: the three stops follow the space the sheet sits in. */
	function measure(node: HTMLElement): () => void {
		const stage = node.parentElement ?? node;
		const fit = (): void => {
			// The sheet may cover the thread, never the toolbar and tabs above it.
			const above = node.previousElementSibling as HTMLElement | null;
			const room = stage.clientHeight - (above ? above.offsetTop : 0);
			untrack(() => (ui.sheetHeights = sheetStops(room, window.innerHeight)));
		};
		const observer = new ResizeObserver(fit);
		observer.observe(stage);
		fit();
		return () => {
			observer.disconnect();
			untrack(() => (ui.sheet = 0));
		};
	}
</script>

<section
	class="sheet"
	class:anim={!ui.sheetDragging}
	style:height="{tall}px"
	style:transform="translate3d(0, {-height}px, 0)"
	aria-label="Board"
	data-sheet
	data-stop={ui.sheet}
	{@attach measure}
>
	<button
		class="grip"
		aria-label="Board, {summary}, {STOPS[ui.sheet]}"
		aria-expanded={ui.sheet > 0}
		onclick={() => ui.stepSheet()}
	>
		<span class="bar"></span>
		<span class="sum">{summary}</span>
	</button>

	<div class="list" inert={ui.sheet === 0} data-sheet-list>
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
	.sheet {
		/* Hung below the stage and lifted by its height, so a new size never animates. */
		position: absolute;
		left: 0;
		right: 0;
		top: 100%;
		z-index: 5;
		display: flex;
		flex-direction: column;
		background: var(--mgr);
		border-top: 1px solid #2b2b3d;
		border-radius: 16px 16px 0 0;
		box-shadow: 0 -8px 24px rgba(0, 0, 0, 0.45);
		will-change: transform;
	}

	/* A little past its target and back: the sheet lands like a spring. */
	.sheet.anim {
		transition: transform 0.36s cubic-bezier(0.2, 1.25, 0.35, 1);
	}

	/*
	 * Every drag on the sheet is ours: up and down move it or scroll its list,
	 * sideways swipes a card away or opens the sidebar.
	 */
	.sheet,
	.sheet :global(*) {
		touch-action: none;
	}

	.grip {
		flex: none;
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		gap: 6px;
		width: 100%;
		height: 46px;
	}

	.bar {
		width: 36px;
		height: 4px;
		border-radius: 2px;
		background: #4a4a5e;
	}

	.sum {
		font-size: 12px;
		color: var(--muted);
	}

	/* Moved by the gesture controller, and only at the tall stop. */
	.list {
		flex: 1;
		min-height: 0;
		overflow: hidden;
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

	.end {
		height: 24px;
	}
</style>
