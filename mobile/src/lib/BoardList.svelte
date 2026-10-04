<script lang="ts">
	import { resolve } from '$app/paths';
	import { age, dotClass, statusLabel } from './format';
	import { swipeAway } from './gestures.svelte';
	import { live } from './live.svelte';
	import { maestro } from './maestro.svelte';
	import { needsYouCards } from './manager';
	import { manager } from './manager.svelte';
	import { needCount, pointCards } from './panel';
	import type { Thread } from './types';

	/**
	 * The board's cards: the sessions that need the user, the review list and
	 * the updates. The home page draws it under its footer, the Maestro panel
	 * at its full stop. A card that names a session opens it with Go.
	 */

	/** How many of the manager's updates the board lists. */
	const UPDATES = 5;

	const points = $derived(pointCards(manager.points, live.threads));
	const pointed = $derived(new Set(points.map((card) => card.thread?.id)));
	const all = $derived(needsYouCards(live.threads ?? [], manager.needsYou));
	/** The sessions that wait and that the Maestro did not point at. */
	const waiting = $derived(all.filter((card) => !pointed.has(card.thread.id)));
	const needs = $derived(needCount(all, points));
	const review = $derived(manager.review);
	const updates = $derived(manager.updates.slice(0, UPDATES));

	const href = (thread: Thread): string => resolve('/t/[id]', { id: thread.id });

	/** A card's link was tapped: the session opens, and its page shows the way back. */
	function opened(event: MouseEvent): void {
		const link = (event.target as Element).closest('a[href]');
		if (link) maestro.jump(link.getAttribute('href') ?? '');
	}
</script>

<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
<div class="in" onclick={opened}>
	{#if points.length || waiting.length}
		<div class="sect">Needs you · {needs}</div>
		{#each points as card (card.key)}
			{@const thread = card.thread}
			{@const name = thread ? `${thread.session} · ${thread.name}` : card.title}
			<div
				class="item"
				data-point={card.key}
				data-stale={card.stale ?? undefined}
				{@attach swipeAway(() => void manager.dismiss(card.key))}
			>
				<svelte:element
					this={thread ? 'a' : 'div'}
					class="open"
					href={thread ? href(thread) : undefined}
					data-thread={thread?.id}
				>
					<span class="sev point" class:stale={card.stale !== null}></span>
					<span class="body">
						<b>
							<i class="dot {thread ? dotClass(thread) : ''}"></i>{name}
						</b>
						<span>
							{#if thread}<i class="hchip" style:background={thread.hostColor}>{thread.host}</i
								>{/if}
							{#if card.stale === 'gone'}Closed ·{:else if thread && card.stale}{statusLabel(
									thread
								)} ·{/if}
							<span class:struck={card.stale !== null} data-reason>{card.reason}</span>
						</span>
					</span>
					<span class="go" class:off={!thread} aria-disabled={!thread} data-go>Go</span>
				</svelte:element>
				<button
					class="tb done"
					aria-label="Dismiss {name}"
					onclick={() => manager.dismiss(card.key)}>✓</button
				>
			</div>
		{/each}
		{#each waiting as { thread, why } (thread.id)}
			<a class="item" href={resolve('/t/[id]', { id: thread.id })} data-thread={thread.id}>
				<span class="sev blocked"></span>
				<span class="body">
					<b>{thread.session} · {thread.name}</b>
					<span>{why ?? 'needs you'} · {age(thread.since ?? thread.lastPrompt?.at, live.now)}</span>
				</span>
				<span class="go" data-go>Go</span>
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
					href={thread ? href(thread) : undefined}
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
				href={thread ? href(thread) : undefined}
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

<style>
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

	/* The Maestro's own pointer. */
	.sev.point {
		background: var(--purple);
	}

	.sev.stale {
		background: #4a4a5e;
	}

	.body {
		flex: 1;
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

	.item .dot {
		display: inline-block;
		width: 8px;
		height: 8px;
		margin: 0 7px 1px 0;
	}

	.hchip {
		font-style: normal;
		color: #000;
		font-weight: 600;
		border-radius: 5px;
		padding: 0 6px;
		margin-right: 3px;
		font-size: 11px;
	}

	.struck {
		text-decoration: line-through;
	}

	/* 44pt of touch area on a small pill: the card around it is the link. */
	.go {
		flex: none;
		align-self: center;
		min-width: var(--hit);
		padding: 5px 12px;
		border-radius: 999px;
		background: var(--purple);
		color: #0d0d14;
		font-size: 13px;
		font-weight: 600;
		text-align: center;
	}

	.go.off {
		background: #2b2b3d;
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
		height: calc(16px + var(--safe-bottom, env(safe-area-inset-bottom)));
	}
</style>
