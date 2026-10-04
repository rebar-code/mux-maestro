<script lang="ts">
	import { resolve } from '$app/paths';
	import { age } from '$lib/format';
	import { pullToRefresh, swipeAway, ui } from '$lib/gestures.svelte';
	import Composer from '$lib/Composer.svelte';
	import { counts } from '$lib/group';
	import { can, live } from '$lib/live.svelte';
	import { needsYouCards } from '$lib/manager';
	import { manager } from '$lib/manager.svelte';
	import Prose from '$lib/Prose.svelte';
	import PullIndicator from '$lib/PullIndicator.svelte';
	import TalkButton from '$lib/TalkButton.svelte';
	import { voice } from '$lib/voice.svelte';
	import VoiceBar from '$lib/VoiceBar.svelte';

	const PULL = 'home';
	/** How many of the manager's updates the home lists. */
	const UPDATES = 5;

	const tally = $derived(live.threads ? counts(live.threads) : null);
	const managerOn = $derived(can('manager'));
	// A take goes to the manager, so voice needs the manager's switch too.
	const voiceOn = $derived(managerOn && can('voice'));
	const waiting = $derived(needsYouCards(live.threads ?? [], managerOn ? manager.needsYou : []));
	const review = $derived(managerOn ? manager.review : []);

	async function reload(): Promise<void> {
		await Promise.all([live.refresh(), managerOn ? manager.load() : null]);
	}

	function send(): void {
		// A typed turn takes over: a reply that is still being read stops.
		if (voiceOn) voice.skip();
		void manager.send();
	}
</script>

<header class="tbar">
	<button class="tb" aria-label="Menu" onclick={() => ui.openDrawer()}>☰</button>
	<div class="chips">
		{#if tally}
			<button class="chip grow" class:red={tally.waiting > 0} onclick={() => ui.openDrawer()}
				>{tally.waiting} need you</button
			>
			<button class="chip grow green" onclick={() => ui.openDrawer()}>{tally.busy} running</button>
			<button class="chip grow" onclick={() => ui.openDrawer()}>💤 {tally.dozing}</button>
		{:else}
			<span class="skel" style:width="76px" style:height="23px" style:border-radius="999px"></span>
			<span class="skel" style:width="72px" style:height="23px" style:border-radius="999px"></span>
			<span class="skel" style:width="48px" style:height="23px" style:border-radius="999px"></span>
		{/if}
	</div>
</header>

<div class="scroll home" data-pull={PULL} {@attach pullToRefresh(PULL, reload)}>
	<PullIndicator key={PULL} />
	<!-- Until the Mac says which features are on, hold the button's place. -->
	{#if voiceOn}
		<div class="hero">
			<TalkButton target="manager" sink={manager.voice} orb />
		</div>
	{:else if live.config === null}
		<div class="hero" aria-hidden="true"></div>
	{/if}

	{#if managerOn}
		<div class="said" aria-live="polite" data-said {@attach manager.watch}>
			{#each manager.lines as line, index (index)}
				{#if line.role === 'user'}
					<div class="u">{line.text}</div>
				{:else if line.text}
					<div class="m" class:old={index < manager.lines.length - 1}>
						<Prose text={line.text} />
					</div>
				{:else}
					<div class="m wait" role="status" aria-label="Thinking">
						<i></i><i></i><i></i>
					</div>
				{/if}
			{/each}
			{#if manager.note}
				<div class="note" role="alert">{manager.note}</div>
			{:else if manager.statusNote}
				<div class="note quiet" role="status" data-status={manager.status}>
					{manager.statusNote}
				</div>
			{/if}
		</div>
	{/if}

	{#if waiting.length}
		<div class="sect">Needs you · {waiting.length}</div>
		{#each waiting as { thread, why } (thread.id)}
			<a class="item" href={resolve('/t/[id]', { id: thread.id })} data-thread={thread.id}>
				<span class="sev blocked"></span>
				<span class="body">
					<b>{thread.session} · {thread.name}</b>
					<span>{why ?? 'needs you'} · {age(thread.since ?? thread.lastPrompt?.at, live.now)}</span>
				</span>
			</a>
		{/each}
	{/if}

	{#if review === null}
		<div class="sect">Review</div>
		<div class="skcard skel" aria-hidden="true"></div>
	{:else if review.length}
		<div class="sect">Review · {review.length}</div>
		{#each review as item (item.key)}
			{@const thread = item.thread ? live.byId(item.thread) : undefined}
			{@const key = item.key ?? ''}
			<div class="item" data-review={key} {@attach swipeAway(() => void manager.dismiss(key))}>
				<svelte:element
					this={thread ? 'a' : 'div'}
					class="open"
					href={thread ? resolve('/t/[id]', { id: thread.id }) : undefined}
				>
					<span class="sev {item.severity ?? 'info'}"></span>
					<span class="body">
						<b>{thread ? `${thread.session} · ${thread.name}` : item.title}</b>
						<span>{item.detail}</span>
					</span>
				</svelte:element>
				<button
					class="tb done"
					aria-label="Dismiss {thread ? `${thread.session} · ${thread.name}` : item.title}"
					onclick={() => manager.dismiss(key)}>✓</button
				>
			</div>
		{/each}
	{/if}
	{#if managerOn && manager.updates.length}
		<div class="sect">Updates</div>
		{#each manager.updates.slice(0, UPDATES) as update, index (index)}
			{@const thread = update.thread ? live.byId(update.thread) : undefined}
			<svelte:element
				this={thread ? 'a' : 'div'}
				class="upd"
				class:grow={thread !== undefined}
				href={thread ? resolve('/t/[id]', { id: thread.id }) : undefined}
				data-update
			>
				<span class="what">
					{#if thread}<b>{thread.session} · {thread.name}</b>{/if}
					{update.text}
				</span>
				<span class="when">{age(update.at, live.now)}</span>
			</svelte:element>
		{/each}
	{/if}
	<div class="end"></div>
</div>

{#if managerOn}
	{#if voiceOn}
		<VoiceBar target="manager" sink={manager.voice} />
	{/if}
	<Composer
		bind:value={manager.draft}
		label="Ask the manager"
		target="manager"
		sink={manager.voice}
		{voiceOn}
		blocked={manager.busy}
		onsend={send}
	/>
{/if}

<style>
	.home {
		background: var(--mgr);
	}

	.hero {
		display: flex;
		flex-direction: column;
		align-items: center;
		/* The button's height, so the lines below do not move when it lands. */
		min-height: 180px;
		padding: 22px 0 10px;
	}

	.said {
		display: flex;
		flex-direction: column;
		gap: 10px;
		/* Room for one line, so the cards do not jump when the first one lands. */
		min-height: 46px;
		padding: 10px 18px 4px;
		text-align: center;
	}

	.u {
		color: var(--muted);
		font-size: 13.5px;
		overflow-wrap: anywhere;
	}

	.m {
		color: #dcdcf0;
		font-size: 16px;
		overflow-wrap: anywhere;
	}

	/* An older reply keeps to three lines; the newest one is read in full. */
	.m.old {
		display: -webkit-box;
		-webkit-box-orient: vertical;
		-webkit-line-clamp: 3;
		line-clamp: 3;
		overflow: hidden;
	}

	.wait {
		display: flex;
		justify-content: center;
		gap: 5px;
		padding: 8px 0;
	}

	.wait i {
		width: 6px;
		height: 6px;
		border-radius: 50%;
		background: var(--purple);
		animation: think 1s ease-in-out infinite alternate;
	}

	.wait i:nth-child(2) {
		animation-delay: 0.2s;
	}

	.wait i:nth-child(3) {
		animation-delay: 0.4s;
	}

	@keyframes think {
		from {
			opacity: 0.25;
		}
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

	.upd {
		position: relative;
		display: flex;
		align-items: baseline;
		gap: 10px;
		margin: 0 14px;
		padding: 7px 2px;
		border-bottom: 1px solid #22222e;
		font-size: 13px;
		color: var(--muted);
	}

	.what {
		flex: 1;
		min-width: 0;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.what b {
		color: var(--text);
		font-weight: 600;
		margin-right: 4px;
	}

	.when {
		flex: none;
		font-size: 12px;
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

	.open {
		flex: 1;
		min-width: 0;
		display: flex;
		gap: 10px;
	}

	.sev {
		flex: none;
		width: 4px;
		border-radius: 2px;
		background: var(--accent);
	}

	.sev.warn {
		background: var(--amber);
	}

	.sev.blocked {
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

	/* A 44pt touch area that does not make the card taller. */
	.done {
		align-self: center;
		margin: -8px -8px -8px 0;
		color: var(--muted);
	}

	.skcard {
		height: 62px;
		margin: 0 14px 8px;
		border-radius: 12px;
	}

	.end {
		height: 24px;
	}
</style>
