<script lang="ts">
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { sessionTarget } from './actions';
	import { menu } from './actions.svelte';
	import { isCollapsed, sessionDomId, SUMMARY_LABEL, summaryStatus } from './collapse';
	import { collapse } from './collapse.svelte';
	import { pullToRefresh, ui } from './gestures.svelte';
	import FilterButton from './FilterButton.svelte';
	import { counts, GROUPINGS, sections, visible } from './group';
	import HostCard from './HostCard.svelte';
	import Icon from './Icon.svelte';
	import { can, live } from './live.svelte';
	import { longPress } from './longpress';
	import { manager } from './manager.svelte';
	import NotifyRow from './NotifyRow.svelte';
	import { maestroDot, maestroState } from './panel';
	import PullIndicator from './PullIndicator.svelte';
	import { SEARCH_MAX } from './search';
	import SearchResults from './SearchResults.svelte';
	import ThreadRow from './ThreadRow.svelte';

	const PULL = 'threads';

	// The clock is read only while a filter is on: a list with none does not follow it.
	const shown = $derived(
		live.threads && live.filter !== 'off'
			? visible(live.threads, live.filter, live.now)
			: live.threads
	);
	const groups = $derived(shown ? sections(shown, live.grouping) : []);
	const maestro = $derived(
		maestroDot(
			maestroState({ on: can('manager'), busy: manager.busy, status: manager.status }),
			manager.idleStage
		)
	);
	const waiting = $derived(live.threads ? counts(live.threads).waiting : 0);
	const onHome = $derived(page.route.id === '/');
	const openId = $derived(page.route.id === '/t/[id]' ? page.params.id : null);
	const closed = $derived(ui.drawer === 0 && !ui.dragging);

	let scroller = $state<HTMLElement>();

	/** The filter changes the list's length: show all of it, from its top. */
	const filterChanged = (): void => {
		if (live.filter !== 'off') collapse.expandAll();
		scroller?.scrollTo({ top: 0 });
	};

	const searching = $derived(ui.search.trim() !== '');

	function onkeydown(event: KeyboardEvent): void {
		if (event.key === 'Escape') ui.search = '';
		else if (event.key === 'Enter') (event.currentTarget as HTMLElement).blur();
	}
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
		<button
			class="tb"
			aria-label="Refresh"
			disabled={ui.refreshing !== null}
			onclick={() => ui.refresh(PULL)}>↻</button
		>
	</div>

	<div
		class="scroll"
		bind:this={scroller}
		data-pull={PULL}
		{@attach pullToRefresh(PULL, live.refresh)}
	>
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
					{@const shut = isCollapsed(collapse.keys, session.key, session.threads, collapse.opened)}
					<!-- The header sticks inside its own session: the next session pushes it out. -->
					<div class="sess">
						<!-- The row is the long-press target; the two buttons inside it are siblings,
					     so the ＋ never toggles the session. -->
						<div
							class="shead"
							class:shut
							data-session={session.key}
							{@attach can('sessionActions') && longPress(() => menu.open(sessionTarget(session)))}
						>
							<button
								class="fold"
								aria-expanded={!shut}
								aria-controls={sessionDomId(session.key)}
								onclick={() => collapse.toggle(session.key, shut, session.threads)}
							>
								<span class="chev" aria-hidden="true">›</span>
								<b>{session.name}</b>
								<span
									class="host"
									style:color={session.hostColor}
									style:border-color="{session.hostColor}66">{session.host}</span
								>
								{#if shut}
									{@const summary = summaryStatus(session.threads)}
									<span class="dot sum {summary}" data-summary={summary}>
										<span class="sr">{SUMMARY_LABEL[summary]}</span>
									</span>
								{/if}
								<span class="cnt">{session.threads.length}</span>
							</button>
							<button
								class="tb add"
								disabled={!can('sessionActions') || menu.busy}
								aria-disabled={!can('sessionActions')}
								aria-label="New window in {session.name}"
								data-no-hold
								onclick={() => menu.openStart(sessionTarget(session))}>＋</button
							>
						</div>
						<div class="windows" class:shut id={sessionDomId(session.key)} inert={shut}>
							<div class="clip">
								{#each session.threads as thread (thread.id)}
									<ThreadRow {thread} selected={thread.id === openId} />
								{/each}
							</div>
						</div>
					</div>
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
		{#if can('notifications')}
			<div class="sect">This phone</div>
			<NotifyRow />
		{/if}
		<div class="end"></div>
	</div>

	{#if searching}<SearchResults />{/if}

	<!-- Always here, in reach of a thumb: the search, and the way back to the home. -->
	<div class="dbar">
		<FilterButton onchange={filterChanged} />
		<label class="find" role="search">
			<Icon name="search" size={16} />
			<input
				type="search"
				enterkeyhint="search"
				autocomplete="off"
				autocapitalize="off"
				autocorrect="off"
				spellcheck="false"
				maxlength={SEARCH_MAX}
				placeholder="Search"
				aria-label="Search"
				bind:value={ui.search}
				{onkeydown}
			/>
			{#if ui.search}
				<button
					class="tb clear"
					type="button"
					aria-label="Clear search"
					onclick={() => (ui.search = '')}>✕</button
				>
			{/if}
		</label>
		<a
			class="mrow"
			class:sel={onHome}
			class:sleep={maestro?.sleeps}
			href={resolve('/')}
			aria-label="Maestro"
			aria-current={onHome ? 'page' : undefined}
			title={maestro?.label}
			data-home
			data-state={maestro?.label}
			onclick={() => ui.closeDrawer()}
		>
			<span aria-hidden="true">✦</span>
			{#if maestro}<span class="stat"><span class="dot {maestro.dot}"></span></span>{/if}
			{#if maestro?.sleeps}<span class="tag">💤</span>{/if}
			{#if waiting}<span class="badge">{waiting}</span>{/if}
		</a>
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
		flex: none;
		gap: 8px;
		padding-right: 8px;
	}

	.dtop .seg {
		flex: 1;
		margin-right: 0;
	}

	/* Fixed under the list: the list ends above it, and it clears the home indicator. */
	.dbar {
		display: flex;
		align-items: center;
		gap: 8px;
		flex: none;
		padding: 8px 14px calc(8px + env(safe-area-inset-bottom));
		border-top: 1px solid var(--border);
		background: var(--bar);
	}

	/* Over the search results, which lie over the rest of the sidebar. */
	.dbar {
		position: relative;
		z-index: 3;
	}

	.find {
		flex: 1;
		min-width: 0;
		display: flex;
		align-items: center;
		gap: 6px;
		height: 46px;
		padding-left: 10px;
		border: 1px solid #2b2b3d;
		border-radius: 10px;
		background: var(--bg);
		color: var(--muted);
	}

	.find:focus-within {
		border-color: var(--accent);
	}

	.find input {
		flex: 1;
		min-width: 0;
		height: 100%;
		background: none;
		border: 0;
		padding: 0;
		color: var(--text);
		font: inherit;
		/* Under 16px, iOS zooms the page when the box takes focus. */
		font-size: 16px;
		outline: none;
		appearance: none;
	}

	.find input::-webkit-search-cancel-button {
		display: none;
	}

	.clear {
		min-width: 36px;
		color: var(--muted);
	}

	.mrow {
		flex: none;
		position: relative;
		display: flex;
		align-items: center;
		justify-content: center;
		width: 46px;
		height: 46px;
		border-radius: 50%;
		background: var(--mgr);
		border: 1px solid #2b2b3d;
		color: var(--purple);
		font-size: 17px;
	}

	.mrow.sel {
		background: #1b2333;
	}

	.mrow.sleep {
		color: #8a8a8a;
	}

	/* The dot on a disc of the bar's colour, on the button's rim, as on an avatar. */
	.stat {
		position: absolute;
		right: -2px;
		bottom: -2px;
		padding: 3px;
		border-radius: 50%;
		background: var(--bar);
	}

	.stat .dot {
		display: block;
		margin-top: 0;
	}

	.mrow .tag {
		position: absolute;
		left: -3px;
		bottom: -3px;
		font-size: 11px;
	}

	.badge {
		position: absolute;
		right: -4px;
		top: -4px;
		min-width: 17px;
		height: 17px;
		border-radius: 9px;
		background: var(--red);
		color: #fff;
		font-size: 11px;
		font-weight: 600;
		line-height: 17px;
		text-align: center;
		padding: 0 4px;
	}

	.shead {
		display: flex;
		align-items: center;
		gap: 7px;
		padding: 13px 8px 4px 0;
		font-size: 13px;
		color: #b5b5b5;
		/* Stays at the top of the list while its windows scroll under it. */
		position: sticky;
		top: 0;
		z-index: 1;
		background: var(--bar);
	}

	/* The header's tap target: everything but the ＋. */
	.fold {
		flex: 1;
		min-width: 0;
		display: flex;
		align-items: center;
		position: relative;
		gap: 7px;
		padding: 0 0 0 4px;
		color: inherit;
		font: inherit;
		text-align: left;
	}

	/* 44pt of touch area around the 18pt line, clear of the ＋ beside it. */
	.fold::after {
		content: '';
		position: absolute;
		inset: -14px 0;
	}

	.chev {
		flex: none;
		width: 10px;
		text-align: center;
		color: var(--muted);
		transform: rotate(90deg);
		transition: transform 0.18s var(--ease);
	}

	.shut .chev {
		transform: none;
	}

	.shead b {
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.sum {
		margin-top: 0;
	}

	/* Read by a screen reader, not drawn. */
	.sr {
		position: absolute;
		width: 1px;
		height: 1px;
		overflow: hidden;
		clip-path: inset(50%);
		white-space: nowrap;
	}

	/* Rows fold away by animating the grid track from 1fr to 0fr: the height
	   follows the content without measuring it. */
	.windows {
		display: grid;
		grid-template-rows: 1fr;
		transition: grid-template-rows 0.18s var(--ease);
	}

	.windows.shut {
		grid-template-rows: 0fr;
	}

	.clip {
		min-height: 0;
		overflow: hidden;
	}

	/* Hidden rows must not be reachable or found by a reader. */
	.windows.shut .clip {
		visibility: hidden;
		transition: visibility 0s 0.18s;
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
		padding: 0 14px 0 20px;
	}

	.skcard {
		height: 84px;
		margin: 0 12px 8px;
		border-radius: 12px;
	}

	.end {
		height: 24px;
	}
</style>
