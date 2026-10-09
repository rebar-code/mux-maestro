<script lang="ts">
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { sessionTarget } from './actions';
	import { menu } from './actions.svelte';
	import { ui } from './gestures.svelte';
	import { can, live } from './live.svelte';
	import { searchAll } from './search';
	import ThreadRow from './ThreadRow.svelte';

	/** What the sidebar's search box finds, over the list. A pick ends the search. */
	const found = $derived(searchAll(ui.search, live.threads ?? [], live.hosts ?? []));
	const none = $derived(found.hosts.length + found.sessions.length + found.threads.length === 0);
	const openId = $derived(page.route.id === '/t/[id]' ? page.params.id : null);
	const off = $derived(!can('sessionActions'));
</script>

<div class="found" role="dialog" aria-modal="true" aria-label="Search results" data-search-results>
	{#if none}
		<div class="none">No matches</div>
	{/if}
	{#if found.hosts.length}
		<div class="sect">Hosts</div>
		{#each found.hosts as host (host.name)}
			<div class="res" data-found-host={host.name}>
				<span class="name" style:color={host.color}>{host.name}</span>
				<span class="cnt">{host.threads}</span>
				<button
					class="tb add"
					disabled={off}
					aria-disabled={off}
					aria-label="New session on {host.name}"
					onclick={() => {
						ui.search = '';
						menu.openDirs(host.name);
					}}>＋</button
				>
			</div>
		{/each}
	{/if}
	{#if found.sessions.length}
		<div class="sect">Sessions</div>
		{#each found.sessions as session (session.key)}
			<div class="res" data-found-session={session.key}>
				<a
					class="go"
					href={resolve('/t/[id]', { id: session.threads[0].id })}
					onclick={() => ui.closeDrawer()}
				>
					<span class="name">{session.name}</span>
					<span
						class="host"
						style:color={session.hostColor}
						style:border-color="{session.hostColor}66">{session.host}</span
					>
					<span class="cnt">{session.threads.length}</span>
				</a>
				<button
					class="tb add"
					disabled={off || menu.busy}
					aria-disabled={off}
					aria-label="New window in {session.name}"
					onclick={() => {
						ui.search = '';
						menu.openStart(sessionTarget(session));
					}}>＋</button
				>
			</div>
		{/each}
	{/if}
	{#if found.threads.length}
		<div class="sect">Windows</div>
		{#each found.threads as thread (thread.id)}
			<ThreadRow {thread} selected={thread.id === openId} />
		{/each}
	{/if}
</div>

<style>
	/* Over the whole sidebar; the bar with the search box stays on top of it. */
	.found {
		position: absolute;
		inset: 0;
		z-index: 2;
		overflow-y: auto;
		overscroll-behavior: contain;
		padding: env(safe-area-inset-top) 0 calc(88px + env(safe-area-inset-bottom));
		background: var(--bar);
	}

	.none {
		padding: 28px 20px;
		color: var(--muted);
		text-align: center;
	}

	.res {
		display: flex;
		align-items: center;
		gap: 7px;
		min-height: var(--hit);
		padding: 0 8px 0 20px;
	}

	.go {
		flex: 1;
		min-width: 0;
		display: flex;
		align-items: center;
		gap: 7px;
		align-self: stretch;
	}

	.name {
		font-weight: 600;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.host {
		flex: none;
		font-size: 11px;
		border: 1px solid var(--border);
		border-radius: 5px;
		padding: 0 5px;
	}

	.cnt {
		margin-left: auto;
		font-size: 11px;
		color: var(--muted);
	}

	.add {
		color: var(--accent);
		font-size: 16px;
		margin: 0 -7px;
	}
</style>
