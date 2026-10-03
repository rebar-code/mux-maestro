<script lang="ts">
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import type { MenuTarget } from './actions';
	import { menu } from './actions.svelte';
	import { pullToRefresh, ui } from './gestures.svelte';
	import { counts, GROUPINGS, sections, type SessionGroup } from './group';
	import HostCard from './HostCard.svelte';
	import { can, live } from './live.svelte';
	import { longPress } from './longpress';
	import PullIndicator from './PullIndicator.svelte';
	import ThreadRow from './ThreadRow.svelte';

	const PULL = 'threads';

	const groups = $derived(live.threads ? sections(live.threads, live.grouping) : []);
	const waiting = $derived(live.threads ? counts(live.threads).waiting : 0);
	const openId = $derived(page.route.id === '/t/[id]' ? page.params.id : null);
	const closed = $derived(ui.drawer === 0 && !ui.dragging);

	const sessionTarget = (session: SessionGroup): MenuTarget => ({
		kind: 'session',
		host: session.host,
		session: session.name,
		thread: session.threads[0].id
	});
</script>

<aside
	class="drawer"
	class:anim={!ui.dragging}
	style:transform="translate3d({(ui.drawer - 1) * 100}%, 0, 0)"
	style:visibility={closed ? 'hidden' : 'visible'}
	inert={closed}
	data-drawer
	aria-label="Threads"
>
	<div class="dtop">
		{#if can('manager')}
			<a
				class="mrow grow"
				class:sel={page.route.id === '/'}
				href={resolve('/')}
				onclick={() => ui.closeDrawer()}
			>
				<span>✦ Manager</span>
				{#if waiting}<span class="badge">{waiting}</span>{/if}
			</a>
		{:else}
			<span class="mgap"></span>
		{/if}
		<button
			class="tb"
			aria-label="Refresh"
			disabled={ui.refreshing !== null}
			onclick={() => ui.refresh(PULL)}>↻</button
		>
	</div>

	<div class="seg" role="tablist" aria-label="Group by">
		{#each GROUPINGS as option (option.key)}
			<button
				class="grow"
				class:on={live.grouping === option.key}
				role="tab"
				aria-selected={live.grouping === option.key}
				onclick={() => live.setGrouping(option.key)}>{option.label}</button
			>
		{/each}
	</div>

	<div class="scroll" data-pull={PULL} {@attach pullToRefresh(PULL, live.refresh)}>
		<PullIndicator key={PULL} />

		{#if live.threads === null}
			{#each [0, 1, 2, 3, 4, 5] as n (n)}
				<div class="skrow" aria-hidden="true">
					<span class="skel" style:width="{34 + ((n * 17) % 30)}%" style:height="14px"></span>
					<span class="skel" style:width="{60 + ((n * 11) % 25)}%" style:height="12px"></span>
				</div>
			{/each}
		{:else}
			{#each groups as section (section.key)}
				{#if section.title !== null}
					<div class="sect" class:mono={section.mono}>{section.title}</div>
				{/if}
				{#each section.sessions as session (session.key)}
					<div
						class="shead"
						data-session={session.key}
						{@attach can('sessionActions') && longPress(() => menu.open(sessionTarget(session)))}
					>
						<b>{session.name}</b>
						<span
							class="host"
							style:color={session.hostColor}
							style:border-color="{session.hostColor}66">{session.host}</span
						>
						<span class="cnt">{session.threads.length}</span>
						<button
							class="tb add"
							disabled={!can('sessionActions') || menu.busy}
							aria-disabled={!can('sessionActions')}
							aria-label="New window in {session.name}"
							data-no-hold
							onclick={() => menu.newWindow(sessionTarget(session))}>＋</button
						>
					</div>
					{#each session.threads as thread (thread.id)}
						<ThreadRow {thread} selected={thread.id === openId} />
					{/each}
				{/each}
			{/each}
		{/if}

		<div class="sect" data-hosts>Hosts{live.hosts ? ` · ${live.hosts.length}` : ''}</div>
		{#if live.hosts === null}
			<div class="skcard skel" aria-hidden="true"></div>
		{:else}
			{#each live.hosts as host (host.name)}
				<HostCard {host} />
			{/each}
		{/if}
		<div class="end"></div>
	</div>
</aside>

<style>
	.drawer {
		position: absolute;
		top: 0;
		bottom: 0;
		left: 0;
		width: 86%;
		z-index: 41;
		display: flex;
		flex-direction: column;
		padding-top: calc(8px + env(safe-area-inset-top));
		padding-left: env(safe-area-inset-left);
		background: var(--bar);
		border-right: 1px solid var(--border);
		will-change: transform;
	}

	.drawer.anim {
		transition:
			transform 0.24s var(--ease),
			visibility 0s;
	}

	.dtop {
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 0 8px 2px 14px;
	}

	.mrow {
		flex: 1;
		display: flex;
		align-items: center;
		position: relative;
		justify-content: space-between;
		padding: 9px 12px;
		border-radius: 10px;
		background: var(--mgr);
		border: 1px solid #2b2b3d;
		font-weight: 600;
	}

	/* Its 44pt touch area must not make the top row taller than the Manager row. */
	.dtop .tb {
		margin: -2px 0;
	}

	.mgap {
		flex: 1;
	}

	.mrow.sel {
		background: #1b2333;
	}

	.badge {
		min-width: 19px;
		height: 19px;
		border-radius: 10px;
		background: var(--red);
		color: #fff;
		font-size: 12px;
		line-height: 19px;
		text-align: center;
		padding: 0 5px;
	}

	.shead {
		display: flex;
		align-items: center;
		gap: 7px;
		padding: 13px 8px 4px 14px;
		font-size: 13px;
		color: #b5b5b5;
	}

	.shead b {
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
		/* 44pt of touch area around a 30 x 28pt glyph box. */
		margin: -8px -7px;
	}

	.skrow {
		display: flex;
		flex-direction: column;
		justify-content: center;
		gap: 7px;
		height: 56px;
		padding: 0 14px 0 24px;
	}

	.skcard {
		height: 84px;
		margin: 0 12px 8px;
		border-radius: 12px;
	}

	.end {
		height: calc(24px + env(safe-area-inset-bottom));
	}
</style>
