<script lang="ts">
	import { resolve } from '$app/paths';
	import { pullToRefresh } from '$lib/gestures.svelte';
	import PullIndicator from '$lib/PullIndicator.svelte';
	import { countRequests, groupRequests, isDone, stateLabel } from '$lib/requests';
	import { Requests } from '$lib/requests.svelte';
	import type { RequestHistoryEntry } from '$lib/types';

	/** The page key of the pull-to-refresh. */
	const KEY = 'requests';
	/** The chip colour of each state the Mac names. Any other state is muted. */
	const TONES: Record<string, string> = {
		in_progress: 'accent',
		blocked: 'red',
		review: 'amber'
	};

	const requests = new Requests();

	const rows = $derived(requests.list?.requests ?? []);
	const counts = $derived(countRequests(rows));
	const groups = $derived(groupRequests(rows, requests.done));
	/** A count after a filter's name. None while there is no list: never a wrong 0. */
	const tally = (count: number): string => (requests.list ? ` ${count}` : '');
</script>

<!-- How a request got here, oldest first, so it reads as a story. Nothing here edits it. -->
{#snippet history(id: string, entries: RequestHistoryEntry[] | undefined)}
	{#if Array.isArray(entries) && entries.length}
		<ol class="history" {id} data-history>
			{#each entries as entry, index (index)}
				<li class="entry" class:agent={entry.by === 'maestro'} data-by={entry.by}>
					<div class="who"><b>{entry.by}</b> <span>{entry.at}</span></div>
					{#if entry.verbatim}<blockquote>“{entry.verbatim}”</blockquote>{/if}
					{#if entry.note}<p>{entry.note}</p>{/if}
				</li>
			{/each}
		</ol>
	{:else}
		<p class="history none" {id} data-history>No history</p>
	{/if}
{/snippet}

<svelte:head><title>Requests</title></svelte:head>

<header class="tbar">
	<a class="tb" href={resolve('/')} aria-label="Back">‹</a>
	<div class="title"><b>Requests</b></div>
</header>

<div class="seg">
	<button
		class="grow"
		class:on={!requests.done}
		aria-pressed={!requests.done}
		onclick={() => (requests.done = false)}>Open{tally(counts.open)}</button
	>
	<button
		class="grow"
		class:on={requests.done}
		aria-pressed={requests.done}
		onclick={() => (requests.done = true)}>Done{tally(counts.done)}</button
	>
</div>

<div
	class="scroll"
	data-pull={KEY}
	{@attach pullToRefresh(KEY, requests.load)}
	{@attach requests.watch}
>
	<PullIndicator key={KEY} />
	{#if requests.note}<div class="note" role="alert">{requests.note}</div>{/if}
	{#if requests.error !== null}
		<div class="failed" role="alert" data-error>
			<b>Can't read the request list</b>
			{#if requests.error}<span>{requests.error}</span>{/if}
			<button class="retry" onclick={requests.retry}>Retry</button>
		</div>
	{:else if requests.list === null}
		<div class="sect"><span class="skel" style:width="90px" style:height="11px"></span></div>
		{#each [72, 54, 64] as width (width)}
			<div class="row item">
				<span class="box"><span class="skel" style:width="22px" style:height="22px"></span></span>
				<span class="skel" style:width="{width}%" style:height="15px"></span>
			</div>
		{/each}
	{:else if groups.length === 0}
		<div class="empty">{requests.done ? 'Nothing done' : 'Nothing open'}</div>
	{:else}
		{#each groups as group (group.project)}
			<div class="sect mono" data-project={group.project}>
				{group.project} · {group.requests.length}
			</div>
			{#each group.requests as request (request.id)}
				{@const ticked = isDone(request.state)}
				{@const label = stateLabel(request.state)}
				{@const open = requests.expanded.has(request.id)}
				{@const panel = `history-${request.id}`}
				<div class="item" data-request={request.id}>
					<div class="row">
						<button
							class="box"
							role="checkbox"
							aria-checked={ticked}
							aria-label={request.title}
							disabled={requests.busy === request.id}
							onclick={() => requests.toggle(request)}
						>
							<span class="check" class:on={ticked}>{ticked ? '✓' : ''}</span>
						</button>
						<button
							class="open"
							aria-expanded={open}
							aria-controls={panel}
							onclick={() => requests.toggleHistory(request.id)}
						>
							<span class="name" class:off={ticked}>{request.title}</span>
							{#if label}
								<span class="state {TONES[request.state] ?? 'other'}" data-state={request.state}
									>{label}</span
								>
							{/if}
							<span class="caret" class:turned={open} aria-hidden="true">›</span>
						</button>
					</div>
					{#if open}
						{@render history(panel, request.history)}
					{/if}
				</div>
			{/each}
		{/each}
		<div class="foot"></div>
	{/if}
</div>

<style>
	.tbar a.tb {
		font-size: 26px;
		line-height: 1;
		padding-bottom: 3px;
	}

	.title b {
		font-size: 16px;
	}

	.item {
		border-bottom: 1px solid #161616;
	}

	.row {
		display: flex;
		align-items: center;
		gap: 4px;
		min-height: 52px;
		padding: 4px 8px 4px 4px;
	}

	/* The title, the chip and the caret: one target that opens the history. */
	.open {
		flex: 1;
		min-width: 0;
		display: flex;
		align-items: center;
		min-height: var(--hit);
		border-radius: 8px;
		text-align: left;
	}

	.open:active {
		background: var(--surface);
	}

	.caret {
		flex: none;
		width: 22px;
		margin-left: 4px;
		text-align: center;
		font-size: 18px;
		line-height: 1;
		color: #5a5a5a;
		transition: transform 0.2s var(--ease);
	}

	.caret.turned {
		transform: rotate(90deg);
	}

	/* Indented to the title's left edge; smaller than the row it belongs to. */
	.history {
		margin: 0;
		padding: 0 14px 14px 52px;
		list-style: none;
		font-size: 13px;
		line-height: 1.45;
	}

	.history.none {
		color: var(--muted);
	}

	.entry + .entry {
		margin-top: 12px;
	}

	.who b {
		font-size: 11.5px;
		font-weight: 600;
		color: var(--accent);
	}

	.entry.agent .who b {
		color: var(--purple);
	}

	.who span {
		margin-left: 4px;
		font-size: 11.5px;
		color: var(--muted);
	}

	blockquote {
		margin: 4px 0 0;
		padding-left: 10px;
		border-left: 2px solid var(--accent);
		color: var(--text);
		overflow-wrap: anywhere;
	}

	.entry p {
		margin: 4px 0 0;
		color: var(--muted);
		overflow-wrap: anywhere;
	}

	.box {
		flex: none;
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: var(--hit);
		height: var(--hit);
		border-radius: 8px;
	}

	.box:not(:disabled):active {
		background: var(--surface);
	}

	.check {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 22px;
		height: 22px;
		border: 1.5px solid #5a5a5a;
		border-radius: 6px;
		font-size: 14px;
		font-weight: 700;
		color: var(--bg);
	}

	.check.on {
		background: var(--green);
		border-color: var(--green);
	}

	.name {
		flex: 1;
		min-width: 0;
		padding: 6px 0;
		overflow-wrap: anywhere;
	}

	.name.off {
		color: var(--muted);
	}

	.state {
		flex: none;
		margin-left: 8px;
		padding: 2px 8px;
		border-radius: 999px;
		border: 1px solid currentColor;
		font-size: 11.5px;
		line-height: 1.35;
		white-space: nowrap;
	}

	.state.accent {
		color: var(--accent);
	}

	.state.red {
		color: var(--red);
	}

	.state.amber {
		color: var(--amber);
	}

	.state.other {
		color: var(--muted);
	}

	.note {
		padding: 10px 14px;
		font-size: 13px;
		color: var(--red);
	}

	.failed {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 6px;
		padding: 48px 24px;
		text-align: center;
	}

	.failed span {
		font-size: 13px;
		color: var(--muted);
		overflow-wrap: anywhere;
	}

	.retry {
		margin-top: 10px;
		min-height: var(--hit);
		padding: 0 22px;
		border-radius: 10px;
		background: var(--surface);
		border: 1px solid var(--border);
		color: var(--accent);
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
