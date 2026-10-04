<script lang="ts">
	import { resolve } from '$app/paths';
	import BoardSheet from '$lib/BoardSheet.svelte';
	import { age } from '$lib/format';
	import Composer from '$lib/Composer.svelte';
	import { pullToRefresh, ui } from '$lib/gestures.svelte';
	import { counts } from '$lib/group';
	import KeyBar from '$lib/KeyBar.svelte';
	import { can, isOff, live, OFF_LABEL } from '$lib/live.svelte';
	import { needsYouCards, thinkingText } from '$lib/manager';
	import { manager } from '$lib/manager.svelte';
	import NoteLine from '$lib/NoteLine.svelte';
	import PullIndicator from '$lib/PullIndicator.svelte';
	import { Reply } from '$lib/reply.svelte';
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

	// The manager pane's prompts and keys. Its text goes through the manager's own turn.
	const reply = new Reply(
		'manager',
		{
			refresh: () => {
				// An answer or a key can end the wait: the pane's status is read again too.
				void manager.load();
				return manager.feed.load(terminal ? 'terminal' : 'chat');
			},
			// A card that comes up is what the human has to act on: it is brought into view.
			stick: (change, appeared) =>
				manager.feed.keepEnd(terminal ? 'terminal' : 'chat', appeared, change),
			terminal: () => terminal
		},
		manager.target
	);
	const keysOn = $derived(managerOn && can('keyBar'));

	function send(): void {
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
			{reply}
			bind:terminal
		/>
		<BoardSheet />
	</div>

	<!-- Below the stage, so the board sheet never covers it. -->
	{#if reply.note}<NoteLine note={reply.note} />{/if}
	<!-- The pane's keys only: the text box below belongs to the manager's turns. -->
	{#if keysOn}<KeyBar {reply} composer={false} />{/if}
	<VoiceBar target="manager" sink={manager.voice} off={!voiceOn} />
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
<!-- With the Manager switch off the box stays, disabled, and says where the switch is. -->
<Composer
	bind:value={manager.draft}
	label={boxLabel}
	target="manager"
	sink={manager.voice}
	{voiceOn}
	bare={!managerOn}
	off={!managerOn}
	blocked={manager.busy}
	onsend={send}
/>

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
	/* The manager's thread, with the board sheet over its lower part. */
	.stage {
		position: relative;
		flex: 1;
		min-height: 0;
		display: flex;
		flex-direction: column;
		overflow: hidden;
		/* The board's peek covers this much of the thread's end. */
		--below: 46px;
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
