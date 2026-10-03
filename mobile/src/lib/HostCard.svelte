<script lang="ts">
	import { menu } from './actions.svelte';
	import { hostStatLabels } from './format';
	import { can } from './live.svelte';
	import { longPress } from './longpress';
	import type { Host } from './types';

	const { host }: { host: Host } = $props();

	const cpu = $derived(host.stats?.cpuPercent ?? 0);
	const down = $derived(host.reachability === 'unreachable' || host.reachability === 'tmuxMissing');
</script>

<div
	class="hcard"
	class:down
	style:border-left-color={host.color}
	data-host={host.name}
	{@attach can('sessionActions') && longPress(() => menu.open({ kind: 'host', host: host.name }))}
>
	<div class="l1">
		<span class="hname" style:color={host.color}>{host.name}</span>
		<span class="cnt">{host.threads} {host.threads === 1 ? 'thread' : 'threads'}</span>
		<button
			class="tb add"
			disabled={!can('sessionActions')}
			aria-disabled={!can('sessionActions')}
			aria-label="New session on {host.name}"
			data-no-hold
			onclick={() => menu.openDirs(host.name)}
		>
			＋
		</button>
	</div>
	<div class="bar">
		<i style:width="{Math.min(cpu, 100)}%" style:background={cpu > 65 ? 'var(--amber)' : host.color}
		></i>
	</div>
	<div class="stats">
		{#if host.reachability === 'unreachable'}
			<span>unreachable</span>
		{:else if host.reachability === 'tmuxMissing'}
			<span>no tmux</span>
		{:else}
			{#each hostStatLabels(host) as label (label)}
				<span>{label}</span>
			{/each}
		{/if}
	</div>
</div>

<style>
	.hcard {
		margin: 0 12px 8px;
		padding: 10px 8px 10px 12px;
		border-radius: 12px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-left: 4px solid;
	}

	.down {
		opacity: 0.55;
	}

	.l1 {
		display: flex;
		align-items: center;
		gap: 8px;
		min-height: 28px;
	}

	.hname {
		font-weight: 700;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.cnt {
		margin-left: auto;
		font-size: 12px;
		color: var(--muted);
		flex: none;
	}

	.add {
		color: var(--accent);
		font-size: 17px;
		/* The glyph lines up with the ＋ on the session heads above. */
		margin: -8px -20px -8px -10px;
	}

	.bar {
		height: 5px;
		border-radius: 3px;
		background: #262626;
		margin: 6px 4px 7px 0;
		overflow: hidden;
	}

	.bar i {
		display: block;
		height: 100%;
		border-radius: 3px;
	}

	.stats {
		/* Two fixed rows of two, so every card is the same height. */
		display: grid;
		grid-template-columns: 1fr 1fr;
		grid-auto-rows: 16px;
		gap: 4px 12px;
		min-height: 36px;
		white-space: nowrap;
		font-size: 12px;
		color: var(--muted);
	}
</style>
