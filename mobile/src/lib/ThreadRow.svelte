<script lang="ts">
	import { resolve } from '$app/paths';
	import { menu } from './actions.svelte';
	import { age, dotClass, stageTag, threadTitle } from './format';
	import { ui } from './gestures.svelte';
	import Icon from './Icon.svelte';
	import { can, live } from './live.svelte';
	import { longPress } from './longpress';
	import type { Thread } from './types';

	const { thread, selected }: { thread: Thread; selected: boolean } = $props();

	/** A right swipe pulled the row off its buttons. */
	const open = $derived(ui.revealed === thread.id);

	function tap(event: MouseEvent): void {
		if (!open) return ui.closeDrawer();
		// A tap on a row that is pulled aside puts it back.
		event.preventDefault();
		ui.revealed = null;
	}

	const tag = $derived(stageTag(thread));
	const when = $derived(
		age(thread.lastPrompt?.at ?? thread.lastActivityAt ?? thread.since, live.now)
	);
</script>

<div class="slot" data-reveal-slot>
	{#if can('sessionActions')}
		<div class="acts" data-row-actions inert={!open}>
			<button
				aria-label="Menu for {threadTitle(thread)}"
				onclick={() => {
					ui.revealed = null;
					menu.open({ kind: 'thread', thread });
				}}><Icon name="more" size={20} /></button
			>
			<button
				class="arch"
				aria-label="Archive {threadTitle(thread)}"
				disabled={menu.busy}
				onclick={() => menu.archive({ kind: 'thread', thread })}
				><Icon name="archive" size={20} /></button
			>
		</div>
	{/if}
	<a
		class="row grow"
		class:open
		class:sel={selected}
		class:sleep={thread.idleStage === 'dozing'}
		href={resolve('/t/[id]', { id: thread.id })}
		aria-current={selected ? 'page' : undefined}
		data-thread={thread.id}
		data-reveal={can('sessionActions') ? thread.id : undefined}
		onclick={tap}
		{@attach can('sessionActions') && longPress(() => menu.open({ kind: 'thread', thread }))}
	>
		<span class="dot {dotClass(thread)}"></span>
		<span class="main">
			<span class="l1">
				<span class="name">{threadTitle(thread)}</span>
				<span class="end">
					{#each thread.prs ?? [] as pr (pr.url)}
						<span class="pr {pr.state}" title={pr.title}>#{pr.number}</span>
					{/each}
					<span class="age">{tag ? `${tag} ` : ''}{when}</span>
				</span>
			</span>
			{#if thread.lastPrompt}
				<span class="prompt">{thread.lastPrompt.text}</span>
			{/if}
			{#if thread.status === 'waiting'}
				<span class="why">needs you</span>
			{/if}
		</span>
	</a>
</div>

<style>
	/* Holds the row and, behind it, the buttons a right swipe shows. */
	.slot {
		position: relative;
		overflow: hidden;
	}

	.acts {
		position: absolute;
		inset: 0 auto 0 0;
		display: flex;
	}

	.acts button {
		display: flex;
		align-items: center;
		justify-content: center;
		width: 56px;
		border-radius: 0;
		background: #2a2a2e;
		color: #fff;
	}

	.acts .arch {
		background: var(--amber);
		color: #111;
	}

	.row {
		display: flex;
		position: relative;
		gap: 11px;
		/* Solid: it covers its buttons until it is pulled aside. */
		background: var(--bar);
		transition: transform 0.2s var(--ease);
		padding: 8px 14px 8px 20px;
		text-align: left;
	}

	.row.open {
		transform: translateX(112px);
	}

	.pr {
		font-size: 12px;
		font-variant-numeric: tabular-nums;
		color: var(--green);
	}

	.pr.draft {
		color: var(--muted);
	}

	.pr.merged {
		color: var(--purple);
	}

	.pr.closed {
		color: var(--red);
	}

	.row:active,
	.row.sel {
		background: #1b2333;
	}

	.main {
		flex: 1;
		min-width: 0;
	}

	.l1 {
		display: flex;
		align-items: baseline;
		gap: 6px;
	}

	.name {
		font-weight: 600;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.sleep .name {
		font-weight: 500;
		color: #b5b5b5;
	}

	/* The right end of the first line: the pull requests, then the age. */
	.end {
		display: flex;
		align-items: baseline;
		gap: 6px;
		margin-left: auto;
		flex: none;
	}

	.age {
		font-size: 12px;
		color: var(--muted);
	}

	.prompt {
		display: block;
		color: var(--muted);
		font-size: 13.5px;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
		margin-top: 1px;
	}
</style>
