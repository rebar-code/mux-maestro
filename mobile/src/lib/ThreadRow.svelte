<script lang="ts">
	import { resolve } from '$app/paths';
	import { age, dotClass, stageTag, threadTitle } from './format';
	import { ui } from './gestures.svelte';
	import { live } from './live.svelte';
	import type { Thread } from './types';

	const { thread, selected }: { thread: Thread; selected: boolean } = $props();

	const tag = $derived(stageTag(thread));
	const when = $derived(
		age(thread.lastPrompt?.at ?? thread.lastActivityAt ?? thread.since, live.now)
	);
</script>

<a
	class="row"
	class:sel={selected}
	class:sleep={thread.idleStage === 'dozing'}
	style:border-left-color={thread.hostColor}
	href={resolve('/t/[id]', { id: thread.id })}
	aria-current={selected ? 'page' : undefined}
	data-thread={thread.id}
	onclick={() => ui.closeDrawer()}
>
	<span class="dot {dotClass(thread)}"></span>
	<span class="main">
		<span class="l1">
			<span class="name">{threadTitle(thread)}</span>
			<span class="age">{tag ? `${tag} ` : ''}{when}</span>
		</span>
		{#if thread.lastPrompt}
			<span class="prompt">{thread.lastPrompt.text}</span>
		{/if}
		{#if thread.status === 'waiting'}
			<span class="why">needs you</span>
		{/if}
	</span>
</a>

<style>
	.row {
		display: flex;
		gap: 11px;
		min-height: var(--hit);
		margin-left: 10px;
		padding: 8px 14px 8px 24px;
		border-left: 3px solid transparent;
		text-align: left;
	}

	.row:active,
	.row.sel {
		background: #1b2333;
	}

	.main {
		flex: 1;
		min-width: 0;
		align-self: center;
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

	.age {
		margin-left: auto;
		font-size: 12px;
		color: var(--muted);
		flex: none;
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
