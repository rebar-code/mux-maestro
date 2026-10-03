<script lang="ts">
	import { resolve } from '$app/paths';
	import { age } from '$lib/format';
	import { ui } from '$lib/gestures.svelte';
	import { counts } from '$lib/group';
	import { live } from '$lib/live.svelte';

	const tally = $derived(live.threads ? counts(live.threads) : null);
	const waiting = $derived(live.threads?.filter((thread) => thread.status === 'waiting') ?? []);
</script>

<header class="tbar">
	<button class="tb" aria-label="Menu" onclick={() => ui.openDrawer()}>☰</button>
	<div class="chips">
		{#if tally}
			<button class="chip grow" class:red={tally.waiting > 0} onclick={() => ui.openDrawer()}
				>{tally.waiting} need you</button
			>
			<button class="chip grow green" onclick={() => ui.openDrawer()}>{tally.busy} running</button>
			<button class="chip grow" onclick={() => ui.openDrawer()}>💤 {tally.dozing}</button>
		{:else}
			<span class="skel" style:width="76px" style:height="23px" style:border-radius="999px"></span>
			<span class="skel" style:width="72px" style:height="23px" style:border-radius="999px"></span>
			<span class="skel" style:width="48px" style:height="23px" style:border-radius="999px"></span>
		{/if}
	</div>
</header>

<div class="scroll home">
	<div class="hero">
		<button class="orb" disabled aria-disabled="true" aria-label="Talk to the manager">
			<span>🎙</span>
		</button>
	</div>

	{#if waiting.length}
		<div class="sect">Needs you · {waiting.length}</div>
		{#each waiting as thread (thread.id)}
			<a class="item" href={resolve('/t/[id]', { id: thread.id })} data-thread={thread.id}>
				<span class="sev"></span>
				<span class="body">
					<b>{thread.session} · {thread.name}</b>
					<span>needs you · {age(thread.since ?? thread.lastPrompt?.at, live.now)}</span>
				</span>
			</a>
		{/each}
	{/if}
	<div class="end"></div>
</div>

<style>
	.home {
		background: var(--mgr);
	}

	.hero {
		display: flex;
		flex-direction: column;
		align-items: center;
		padding: 22px 0 20px;
	}

	.orb {
		width: 148px;
		height: 148px;
		border-radius: 50%;
		background: radial-gradient(circle at 35% 30%, #b99cff, #6b3fd6);
		font-size: 52px;
		color: #fff;
	}

	.orb:disabled {
		opacity: 0.28;
		filter: grayscale(0.6);
	}

	.item {
		display: flex;
		gap: 10px;
		min-height: var(--hit);
		margin: 0 14px 8px;
		padding: 11px 12px;
		border-radius: 12px;
		background: #1c1c28;
		border: 1px solid #2b2b3d;
		text-align: left;
	}

	.item:active {
		filter: brightness(1.3);
	}

	.sev {
		flex: none;
		width: 4px;
		border-radius: 2px;
		background: var(--red);
	}

	.body {
		min-width: 0;
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

	.end {
		height: calc(24px + env(safe-area-inset-bottom));
	}
</style>
