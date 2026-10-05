<script lang="ts">
	import { resolve } from '$app/paths';
	import { linkThread } from './cards';
	import { cards } from './cards.svelte';
	import { swipeAway } from './gestures.svelte';
	import { can } from './live.svelte';
	import { maestro } from './maestro.svelte';
	import { manager } from './manager.svelte';
	import type { PointCard } from './panel';

	/**
	 * A pointer the user answers here: a title, its buttons, and the way to the
	 * session. A tap goes to the pane the card came from, not to the Maestro.
	 * A left swipe or the tick dismisses it, as on the board.
	 */
	const { point }: { point: PointCard } = $props();

	const card = $derived(point.card);
	const thread = $derived(point.thread);
	const name = $derived(thread ? `${thread.session} · ${thread.name}` : point.title);
	const opens = $derived(card ? linkThread(card.link) : null);
	const answer = $derived(card?.answered ?? null);
	const failure = $derived(card ? cards.failure(card) : null);
	const sending = $derived(card !== null && cards.sending === card.id);
	// An answer is typed into a session: with replies off the card only points.
	const answers = $derived(can('replies'));
</script>

{#if card}
	<div
		class="card"
		data-card={point.key}
		data-source={card.source}
		aria-busy={sending}
		{@attach swipeAway(() => void manager.dismiss(point.key))}
	>
		<div class="head">
			<b data-card-name>{name}</b>
			{#if opens !== null}
				<a
					class="go"
					href={resolve('/t/[id]', { id: opens })}
					data-go
					onclick={(event) => maestro.jump(event.currentTarget.getAttribute('href') ?? '')}>Go</a
				>
			{/if}
			<button class="tb done" aria-label="Dismiss {name}" onclick={() => manager.dismiss(point.key)}
				>✓</button
			>
		</div>
		<div class="title" data-card-title>{card.title}</div>
		{#if card.body}<div class="body" data-card-body>{card.body}</div>{/if}
		{#if answer}
			<div class="sent" role="status" data-card-answer>Sent · {answer.label}</div>
		{:else if answers && card.actions.length}
			<div class="acts">
				{#each card.actions as action, index (index)}
					<button
						class="act"
						disabled={cards.sending !== null}
						data-card-action={index}
						onclick={() => cards.act(point.key, card, index)}>{action.label}</button
					>
				{/each}
			</div>
		{/if}
		{#if failure}
			<div class="fail" role="alert" data-card-failure>Not sent · {failure}</div>
		{/if}
	</div>
{/if}

<style>
	.card {
		display: flex;
		flex-direction: column;
		gap: 6px;
		padding: 11px 12px;
		border-radius: 12px;
		background: #1c1c28;
		border: 1px solid #2b2b3d;
		border-left: 4px solid var(--purple);
		font-size: 14px;
	}

	.head {
		display: flex;
		align-items: center;
		gap: 8px;
	}

	.head b {
		flex: 1;
		min-width: 0;
		font-size: 13px;
		color: var(--muted);
		font-weight: 600;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.go {
		flex: none;
		padding: 3px 12px;
		border-radius: 999px;
		border: 1px solid #3a3a52;
		font-size: 12.5px;
		font-weight: 600;
		color: var(--text);
	}

	/* A 44pt touch area that does not make the card taller. */
	.done {
		margin: -12px -8px -12px -4px;
		color: var(--muted);
	}

	.title {
		font-weight: 600;
	}

	.body {
		white-space: pre-line;
		color: #b9b9d0;
		font-size: 13px;
	}

	.acts {
		display: flex;
		flex-wrap: wrap;
		gap: 8px;
		margin-top: 2px;
	}

	/* A 44pt touch target: an answer is not tapped by accident, or missed. */
	.act {
		flex: 1 1 0;
		min-width: 88px;
		min-height: 44px;
		padding: 8px 14px;
		border-radius: 10px;
		background: var(--purple);
		color: #fff;
		font-size: 14px;
		font-weight: 600;
	}

	.act + .act {
		background: #2b2b3d;
		color: var(--text);
	}

	.act:disabled {
		opacity: 0.5;
	}

	.sent {
		font-size: 13px;
		color: var(--green);
	}

	.fail {
		font-size: 13px;
		color: var(--red);
	}
</style>
