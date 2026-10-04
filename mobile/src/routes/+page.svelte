<script lang="ts">
	import { resolve } from '$app/paths';
	import BoardSheet from '$lib/BoardSheet.svelte';
	import { age } from '$lib/format';
	import { pullToRefresh, ui } from '$lib/gestures.svelte';
	import { counts } from '$lib/group';
	import { can, isOff, live, OFF_LABEL } from '$lib/live.svelte';
	import { needsYouCards, thinkingText } from '$lib/manager';
	import { manager } from '$lib/manager.svelte';
	import PullIndicator from '$lib/PullIndicator.svelte';
	import ThreadView from '$lib/ThreadView.svelte';

	const PULL = 'home';

	const tally = $derived(live.threads ? counts(live.threads) : null);
	const managerOn = $derived(can('manager'));
	const boxLabel = $derived(isOff('manager') ? OFF_LABEL : 'Ask the manager');
	const waiting = $derived(needsYouCards(live.threads ?? [], []));
	const canSend = $derived(manager.draft.trim() !== '');
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
		<BoardSheet />
	</div>

	<!-- Voice arrives later: its controls are drawn and do nothing. -->
	<div class="vbar" data-voicebar>
		<span class="wave" aria-hidden="true"><i></i><i></i><i></i><i></i></span>
		<div class="vrow">
			<div class="vseg" role="group" aria-label="Voice mode">
				<button disabled aria-disabled="true">Auto</button>
				<button class="on" disabled aria-disabled="true">Manual</button>
			</div>
			<button class="ip" disabled aria-disabled="true" aria-label="Speaker">🔊</button>
			<button class="ip" disabled aria-disabled="true" aria-label="Replay">↻</button>
			<button class="ip" disabled aria-disabled="true" aria-label="Skip">⏭</button>
			<button class="ip" disabled aria-disabled="true" aria-label="Microphone">🎙</button>
		</div>
	</div>
{:else}
	{@render header()}
	<div class="scroll home" data-pull={PULL} {@attach pullToRefresh(PULL, live.refresh)}>
		<PullIndicator key={PULL} />
		<div class="hero">
			<button class="orb" disabled aria-disabled="true" aria-label="Talk to the manager">
				<span>🎙</span>
			</button>
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
<form class="compose" class:bare={!managerOn} onsubmit={submit}>
	{#if managerOn}
		<input
			bind:value={manager.draft}
			placeholder="Ask the manager"
			aria-label="Ask the manager"
			enterkeyhint="send"
			autocomplete="off"
			autocapitalize="sentences"
		/>
	{:else}
		<input disabled placeholder={boxLabel} aria-label={boxLabel} data-off={isOff('manager')} />
	{/if}
	{#if managerOn && canSend}
		<button class="pill send grow" type="submit" disabled={manager.busy}>↑ Send</button>
	{:else}
		<button class="pill grow" type="button" disabled aria-disabled="true" aria-label="Talk"
			>🎙 Talk</button
		>
	{/if}
</form>

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

	.vbar {
		flex: none;
		padding: 7px 12px 2px;
		border-top: 1px solid var(--border);
		background: var(--bar);
	}

	.wave {
		display: flex;
		align-items: center;
		gap: 2px;
		height: 14px;
		margin: 0 2px 7px;
		opacity: 0.4;
	}

	.wave i {
		width: 3px;
		height: 5px;
		border-radius: 2px;
		background: #666;
	}

	.vrow {
		display: flex;
		align-items: center;
		gap: 8px;
	}

	.vseg {
		display: flex;
		width: 136px;
		margin-right: auto;
		padding: 2px;
		border-radius: 9px;
		background: var(--surface);
	}

	.vseg button {
		flex: 1;
		padding: 5px 0;
		border-radius: 7px;
		font-size: 12px;
		color: var(--muted);
	}

	.vseg button.on {
		background: #2a2a2a;
		color: var(--text);
	}

	.ip {
		flex: none;
		width: 36px;
		height: 36px;
		border-radius: 50%;
		background: var(--surface);
		border: 1px solid var(--border);
		font-size: 15px;
	}

	.compose {
		flex: none;
		display: flex;
		align-items: center;
		gap: 8px;
		margin: 0;
		padding: 6px max(10px, env(safe-area-inset-right)) calc(10px + env(safe-area-inset-bottom))
			max(10px, env(safe-area-inset-left));
		background: var(--bar);
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

	.compose.bare {
		padding-top: 8px;
		border-top: 1px solid var(--border);
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
	}

	.pill.send {
		background: var(--accent);
		color: #fff;
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
