<script lang="ts">
	import { hostStatLabels } from './format';
	import type { Host } from './types';

	const { host }: { host: Host } = $props();

	const cpu = $derived(host.stats?.cpuPercent ?? 0);
	const down = $derived(host.reachability === 'unreachable' || host.reachability === 'tmuxMissing');
</script>

<div class="hcard" class:down style:border-left-color={host.color} data-host={host.name}>
	<div class="l1">
		<span class="hname" style:color={host.color}>{host.name}</span>
		<span class="cnt">{host.threads} {host.threads === 1 ? 'thread' : 'threads'}</span>
		<button class="tb add" disabled aria-disabled="true" aria-label="New session on {host.name}">
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
		margin: -8px 0;
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
		display: flex;
		flex-wrap: wrap;
		gap: 4px 12px;
		min-height: 16px;
		font-size: 12px;
		color: var(--muted);
	}
</style>
