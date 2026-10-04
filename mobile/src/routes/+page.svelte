<script lang="ts">
	import { resolve } from '$app/paths';
	import BoardSheet from '$lib/BoardSheet.svelte';
	import { age } from '$lib/format';
	import { pullToRefresh, ui } from '$lib/gestures.svelte';
	import { counts } from '$lib/group';
	import { can, isOff, live, OFF_LABEL } from '$lib/live.svelte';
	import { boardSummary, needsYouCards, thinkingText } from '$lib/manager';
	import { sheetHeight } from '$lib/pager';
	import { manager } from '$lib/manager.svelte';
	import PullIndicator from '$lib/PullIndicator.svelte';
	import TalkButton from '$lib/TalkButton.svelte';
	import ThreadView from '$lib/ThreadView.svelte';
	import { voice } from '$lib/voice.svelte';
	import VoiceBar from '$lib/VoiceBar.svelte';

	const PULL = 'home';

	const tally = $derived(live.threads ? counts(live.threads) : null);
	const managerOn = $derived(can('manager'));
	// A take goes to the manager, so voice needs the manager's switch too.
	const voiceOn = $derived(managerOn && can('voice'));
	const boxLabel = $derived(isOff('manager') ? OFF_LABEL : 'Ask the manager');
	const waiting = $derived(needsYouCards(live.threads ?? [], []));
	const canSend = $derived(manager.draft.trim() !== '');
	/** What the board holds, on the footer's grabber. */
	const summary = $derived(
		boardSummary({
			needsYou: needsYouCards(live.threads ?? [], manager.needsYou).length,
			review: manager.review?.length ?? 0,
			updates: Math.min(manager.updates.length, 5)
		})
	);
	const STOPS = ['closed', 'open', 'full'] as const;
	/** How much of the board shows: the footer's bottom inset gives way to it. */
	const shown = $derived(sheetHeight(ui.sheetHeights, ui.sheet, ui.sheetUp));
	/** The manager thread shows its terminal, not its chat. */
	let terminal = $state(false);
	/** Ticks while a turn runs, for the time beside the dots. */
	let now = $state(Date.now());
	const seconds = $derived(Math.max(0, Math.floor((now - manager.turnSince) / 1000)));

	/** Attachment for the thinking line: a clock, for as long as the line is drawn. */
	function clock(): () => void {
		now = Date.now();
		const timer = setInterval(() => (now = Date.now()), 1000);
		return () => clearInterval(timer);
	}

	function submit(event: SubmitEvent): void {
		event.preventDefault();
		// A typed turn takes over: a reply that is still being read stops.
		if (voiceOn) voice.skip();
		void manager.send();
	}
</script>

{#snippet header()}
	<header class="tbar">
		<button class="tb" aria-label="Menu" onclick={() => ui.openDrawer()}>☰</button>
		<div class="chips">
			{#if tally}
				<button class="chip grow" class:red={tally.waiting > 0} onclick={() => ui.openDrawer()}
					>{tally.waiting} need you</button
				>
				<button class="chip grow green" onclick={() => ui.openDrawer()}>{tally.busy} running</button
				>
				<button class="chip grow" onclick={() => ui.openDrawer()}>💤 {tally.dozing}</button>
			{:else}
				<span class="skel" style:width="76px" style:height="23px" style:border-radius="999px"
				></span>
				<span class="skel" style:width="72px" style:height="23px" style:border-radius="999px"
				></span>
				<span class="skel" style:width="48px" style:height="23px" style:border-radius="999px"
				></span>
			{/if}
		</div>
	</header>
{/snippet}

<!-- What the manager is doing now, after the last row of its chat. -->
{#snippet tail()}
	{#if manager.busy}
		<div class="think" role="status" data-thinking {@attach clock}>
			<span class="dots" aria-hidden="true"><i></i><i></i><i></i></span>
			<span data-thinking-text>{thinkingText(manager.spinner, seconds)}</span>
		</div>
	{/if}
	{#if manager.note ?? manager.statusNote}
		<div class="state">
			{#if manager.note}
				<span class="note" role="alert">{manager.note}</span>
			{:else}
				<span class="note quiet" role="status" data-status={manager.status}
					>{manager.statusNote}</span
				>
			{/if}
			{#if manager.status === 'waiting'}
				<!-- The prompt is answered in the pane: the terminal shows it. -->
				<button class="chip grow" onclick={() => (terminal = true)}>Terminal</button>
			{/if}
		</div>
	{/if}
{/snippet}

{#if managerOn}
	<div class="stage" {@attach manager.watch}>
		<ThreadView
			id="manager"
			feed={manager.feed}
			{header}
			{tail}
			pending={manager.pending}
			bind:terminal
		/>
	</div>
{:else}
	{@render header()}
	<div class="scroll home" data-pull={PULL} {@attach pullToRefresh(PULL, live.refresh)}>
		<PullIndicator key={PULL} />
		<div class="hero">
			<TalkButton target="manager" sink={manager.voice} orb off />
		</div>
		{#if waiting.length}
			<div class="sect">Needs you · {waiting.length}</div>
			{#each waiting as { thread } (thread.id)}
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
{/if}

<!--
	The footer. With the manager on it is the top edge of the board drawer: a
	swipe up on it raises it, and the board shows below. With the Manager switch
	off the box stays, disabled, and says where the switch is.
-->
<div
	class="foot"
	class:bare={!managerOn}
	class:drawer={managerOn}
	style:--board="{managerOn ? shown : 0}px"
	data-foot
	data-sheet={managerOn ? '' : undefined}
>
	{#if managerOn}
		<button
			class="grab"
			aria-label="Board, {summary}, {STOPS[ui.sheet]}"
			aria-expanded={ui.sheet > 0}
			data-grab
			onclick={() => ui.stepSheet()}
		>
			<span class="bar"></span>
			<span class="sum">{summary}</span>
		</button>
		<VoiceBar target="manager" sink={manager.voice} off={!voiceOn} />
	{/if}
	<form class="compose" onsubmit={submit}>
		{#if managerOn}
			<!-- With the keyboard open the footer sits on it and the board stays shut. -->
			<input
				bind:value={manager.draft}
				placeholder="Ask the manager"
				aria-label="Ask the manager"
				enterkeyhint="send"
				autocomplete="off"
				autocapitalize="sentences"
				onfocus={() => ui.lockSheet(true)}
				onblur={() => ui.lockSheet(false)}
			/>
		{:else}
			<input disabled placeholder={boxLabel} aria-label={boxLabel} data-off={isOff('manager')} />
		{/if}
		{#if managerOn && canSend}
			<button class="pill send grow" type="submit" disabled={manager.busy}>↑ Send</button>
		{:else}
			<TalkButton target="manager" sink={manager.voice} off={!voiceOn} />
		{/if}
	</form>
</div>
{#if managerOn}
	<BoardSheet />
{/if}

<style>
	.home {
		background: var(--mgr);
	}

	.hero {
		display: flex;
		flex-direction: column;
		align-items: center;
		padding: 22px 0 10px;
	}

	.note {
		align-self: center;
		font-size: 12.5px;
		color: var(--red);
		background: #1f1110;
		border: 1px solid #5a2320;
		border-radius: 8px;
		padding: 4px 10px;
	}

	.note.quiet {
		color: var(--muted);
		background: var(--surface);
		border-color: var(--border);
	}

	.item {
		display: flex;
		gap: 10px;
		margin: 0 14px 8px;
		padding: 11px 12px;
		border-radius: 12px;
		background: #1c1c28;
		border: 1px solid #2b2b3d;
		text-align: left;
		transition: transform 0.2s var(--ease);
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
		font-size: 13px;
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
		height: 24px;
	}

	/*
	 * The bottom inset is counted once: here while the footer is the last row,
	 * and on the board once the board shows under it.
	 */
	.compose {
		display: flex;
		align-items: center;
		gap: 8px;
		margin: 0;
		padding: 6px max(10px, env(safe-area-inset-right))
			calc(10px + max(0px, env(safe-area-inset-bottom) - var(--board, 0px)))
			max(10px, env(safe-area-inset-left));
	}

	.compose input {
		flex: 1;
		min-width: 0;
		min-height: var(--hit);
		padding: 10px 14px;
		border-radius: 22px;
		border: 1px solid var(--border);
		background: var(--surface);
		color: var(--text);
		/* 16px: a smaller box makes iOS zoom the page on focus. */
		font: inherit;
		font-size: 16px;
		outline: none;
	}

	.foot.bare .compose {
		padding-top: 8px;
	}

	.compose input:disabled {
		opacity: 1;
		color: var(--muted);
		-webkit-text-fill-color: var(--muted);
	}

	.compose input:focus-visible {
		border-color: var(--accent);
	}

	.pill {
		position: relative;
		flex: none;
		height: 40px;
		padding: 0 16px;
		border-radius: 20px;
		background: #fff;
		color: #000;
		font-weight: 600;
		font-size: 14px;
		white-space: nowrap;
		/* As wide as the Talk button it replaces, so the text box does not move. */
		min-width: 104px;
	}

	.pill.send {
		background: var(--accent);
		color: #fff;
	}

	/* The manager's thread. It gets shorter as the footer rises. */
	.stage {
		flex: 1;
		min-height: 0;
		display: flex;
		flex-direction: column;
		overflow: hidden;
		/* The footer is under the thread: the thread itself needs no bottom inset. */
		--below: 0px;
	}

	.foot {
		flex: none;
		background: var(--bar);
		border-top: 1px solid var(--border);
	}

	/*
	 * A drag on the footer moves the drawer. The text box is left to the
	 * browser, so typing and moving the caret work as usual.
	 */
	.foot.drawer,
	.foot.drawer :global(*:not(input)) {
		touch-action: none;
	}

	/* In the footer the grabber is the top edge: the voice bar draws none. */
	.foot :global(.vbar) {
		padding-top: 3px;
		border-top: 0;
		background: none;
	}

	.grab {
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		gap: 4px;
		width: 100%;
		height: 30px;
		position: relative;
	}

	/* 44pt of touch area on a 30pt strip, reaching up over the thread's edge. */
	.grab::after {
		content: '';
		position: absolute;
		left: 0;
		right: 0;
		bottom: 0;
		height: var(--hit);
	}

	.bar {
		width: 36px;
		height: 4px;
		border-radius: 2px;
		background: #4a4a5e;
	}

	.sum {
		font-size: 11.5px;
		line-height: 1.2;
		color: var(--muted);
	}

	.think {
		display: flex;
		align-items: center;
		gap: 9px;
		font-size: 13px;
		color: #b9b9d0;
	}

	.dots {
		display: inline-flex;
		gap: 4px;
	}

	.dots i {
		width: 6px;
		height: 6px;
		border-radius: 50%;
		background: var(--purple);
		animation: think 1s ease-in-out infinite alternate;
	}

	.dots i:nth-child(2) {
		animation-delay: 0.2s;
	}

	.dots i:nth-child(3) {
		animation-delay: 0.4s;
	}

	@keyframes think {
		from {
			opacity: 0.25;
		}
	}

	.state {
		display: flex;
		align-items: center;
		gap: 8px;
	}
</style>
