<script lang="ts">
	import { pullToRefresh } from './gestures.svelte';
	import PullIndicator from './PullIndicator.svelte';
	import { SERVERS, type Servers } from './servers.svelte';
	import type { RunningLink } from './types';

	const { servers }: { servers: Servers } = $props();

	const running = $derived(servers.running);
	const none = $derived(
		running !== null &&
			running.servers.length + running.stacks.length + running.containers.length === 0 &&
			running.unknowns.length === 0 &&
			servers.mappings.length === 0
	);

	/** A tailnet address without its scheme, as the row shows it. */
	const shown = (url: string): string => url.replace(/^https:\/\//, '').replace(/\/$/, '');
</script>

<!-- eslint-disable svelte/no-navigation-without-resolve -- every link here is an outside address, not a route -->

{#snippet port(link: RunningLink)}
	{@const mapping = servers.mapping(link.port)}
	{#if mapping}
		<a
			class="lnk mono on"
			href={mapping.url}
			target="_blank"
			rel="noopener noreferrer"
			data-port={link.port}>{link.label} <small>{link.port}</small> ↗</a
		>
	{:else if link.mappable}
		<button
			class="lnk mono"
			data-port={link.port}
			disabled={servers.busy !== null}
			onclick={() => servers.tap(link.port)}>{link.label} <small>{link.port}</small> ↗</button
		>
	{:else}
		<span class="lnk mono off" data-port={link.port}>{link.label} <small>{link.port}</small></span>
	{/if}
{/snippet}

<div class="scroll" data-pull={SERVERS} {@attach pullToRefresh(SERVERS, servers.load)}>
	<PullIndicator key={SERVERS} />
	{#if servers.note}<div class="note" role="alert">{servers.note}</div>{/if}
	{#if running === null}
		<div class="sect">Servers</div>
		{#each [46, 60] as width (width)}
			<div class="row">
				<span class="skel" style:width="10px" style:height="10px" style:border-radius="50%"></span>
				<span class="main"
					><span class="skel" style:width="{width}%" style:height="15px"></span></span
				>
			</div>
		{/each}
	{:else if none}
		<div class="empty">Nothing running</div>
	{:else}
		{#if servers.mappings.length}
			<div class="sect">On tailnet · {servers.mappings.length}</div>
			{#each servers.mappings as mapping (mapping.port)}
				<div class="row" data-mapping={mapping.port}>
					<a class="grow" href={mapping.url} target="_blank" rel="noopener noreferrer">
						<span class="dot unviewed"></span>
						<span class="main">
							<span class="name">{mapping.label || `:${mapping.port}`}</span>
							<span class="sub mono">🔒 {shown(mapping.url)}</span>
						</span>
						<span class="go">↗</span>
					</a>
					<button
						class="tb"
						aria-label="Close port {mapping.port}"
						disabled={servers.busy !== null}
						onclick={() => servers.close(mapping.port)}>✕</button
					>
				</div>
			{/each}
		{/if}

		{#if running.servers.length}
			<div class="sect">Servers · {running.servers.length}</div>
			{#each running.servers as server (server.key)}
				{@const mapping = servers.mapping(server.port)}
				{@const address = `${server.local ? 'localhost' : server.host}:${server.port}`}
				{#snippet body()}
					<span class="dot unviewed"></span>
					<span class="main">
						<span class="name">{server.label}</span>
						<span class="sub mono">{address}</span>
					</span>
				{/snippet}
				{#if mapping}
					<a
						class="row"
						href={mapping.url}
						target="_blank"
						rel="noopener noreferrer"
						data-server={server.port}
					>
						{@render body()}<span class="go">↗</span>
					</a>
				{:else if server.mappable}
					<button
						class="row"
						data-server={server.port}
						disabled={servers.busy !== null}
						onclick={() => servers.tap(server.port)}
					>
						{@render body()}<span class="go">↗</span>
					</button>
				{:else}
					<div class="row" data-server={server.port}>{@render body()}</div>
				{/if}
			{/each}
		{/if}

		{#if running.stacks.length}
			<div class="sect">Supabase · {running.stacks.length}</div>
			{#each running.stacks as stack (stack.key)}
				<div class="row wrap" data-stack={stack.key}>
					<span class="dot unviewed"></span>
					<span class="main">
						<span class="l1">
							<span class="name">{stack.label}</span>
							<span class="age">{stack.count} containers</span>
						</span>
					</span>
					<div class="links">
						{#each stack.links as link (link.label + link.port)}{@render port(link)}{/each}
					</div>
				</div>
			{/each}
		{/if}

		{#if running.containers.length}
			<div class="sect">Docker · {running.containers.length}</div>
			{#each running.containers as container (container.key)}
				<div class="row wrap" data-container={container.key}>
					<span class="dot unviewed"></span>
					<span class="main">
						<span class="l1">
							<span class="name">{container.label}</span>
							{#if !container.local}<span class="age">{container.host}</span>{/if}
						</span>
					</span>
					{#if container.links.length}
						<div class="links">
							{#each container.links as link (link.port)}{@render port(link)}{/each}
						</div>
					{/if}
				</div>
			{/each}
		{/if}

		{#each running.unknowns as line (line)}
			<div class="unknown">{line}</div>
		{/each}
		<div class="foot"></div>
	{/if}
</div>

<style>
	.row {
		display: flex;
		align-items: center;
		gap: 11px;
		width: 100%;
		min-height: 56px;
		padding: 9px 14px;
		border-bottom: 1px solid #161616;
		text-align: left;
	}

	.row.wrap {
		flex-wrap: wrap;
	}

	.row > a.grow {
		position: static;
		flex: 1;
		min-width: 0;
		display: flex;
		align-items: center;
		gap: 11px;
		min-height: var(--hit);
	}

	.row > a.grow::after {
		content: none;
	}

	a.row:active,
	button.row:not(:disabled):active {
		background: var(--surface);
	}

	.dot {
		margin-top: 0;
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
		display: block;
		font-weight: 600;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.age {
		margin-left: auto;
		flex: none;
		font-size: 12px;
		color: var(--muted);
	}

	.sub {
		display: block;
		margin-top: 1px;
		font-size: 12.5px;
		color: var(--muted);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.go {
		flex: none;
		color: var(--accent);
		font-size: 18px;
		padding: 0 4px;
	}

	.links {
		display: flex;
		flex-wrap: wrap;
		gap: 8px;
		width: 100%;
		padding: 2px 0 2px 21px;
	}

	.lnk {
		display: inline-flex;
		align-items: center;
		gap: 8px;
		min-height: var(--hit);
		padding: 8px 12px;
		border-radius: 10px;
		background: var(--surface);
		border: 1px solid var(--border);
		font-size: 13px;
		color: var(--accent);
	}

	.lnk.on {
		border-color: var(--green);
	}

	.lnk.off {
		color: var(--muted);
	}

	.lnk small {
		color: var(--muted);
	}

	.note,
	.unknown {
		padding: 10px 14px;
		font-size: 13px;
		color: var(--muted);
	}

	.note {
		color: var(--red);
	}

	.empty {
		display: flex;
		align-items: center;
		justify-content: center;
		height: 100%;
		color: var(--muted);
	}

	.foot {
		height: calc(16px + env(safe-area-inset-bottom));
	}
</style>
