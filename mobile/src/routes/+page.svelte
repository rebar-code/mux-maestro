<script lang="ts">
	import { resolve } from '$app/paths';
	import { age } from '$lib/format';
	import { pullToRefresh, swipeAway, ui } from '$lib/gestures.svelte';
	import { counts } from '$lib/group';
	import { can, live } from '$lib/live.svelte';
	import { needsYouCards } from '$lib/manager';
	import { manager } from '$lib/manager.svelte';
	import PullIndicator from '$lib/PullIndicator.svelte';

	const PULL = 'home';

	const tally = $derived(live.threads ? counts(live.threads) : null);
	const managerOn = $derived(can('manager'));
	const waiting = $derived(needsYouCards(live.threads ?? [], managerOn ? manager.needsYou : []));
	const review = $derived(managerOn ? manager.review : []);
	const canSend = $derived(manager.draft.trim() !== '');

	async function reload(): Promise<void> {
		await Promise.all([live.refresh(), managerOn ? manager.load() : null]);
	}

	function submit(event: SubmitEvent): void {
		event.preventDefault();
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
	{#if managerOn || live.config === null}
		<div class="hero">
			<button class="orb" disabled aria-disabled="true" aria-label="Talk to the manager">
				<span>🎙</span>
			</button>
		</div>
	{/if}

	{#if managerOn}
		<div class="said" aria-live="polite" data-said {@attach manager.watch}>
			{#each manager.lines as line, index (index)}
				{#if line.role === 'user'}
					<div class="u">{line.text}</div>
				{:else if line.text}
					<div class="m" class:old={index < manager.lines.length - 1}>{line.text}</div>
				{:else}
					<div class="m wait" role="status" aria-label="Thinking">
						<i></i><i></i><i></i>
					</div>
				{/if}
			{/each}
			{#if manager.note}
				<div class="note" role="alert">{manager.note}</div>
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
	<div class="end"></div>
</div>

{#if managerOn}
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
	<form class="compose" onsubmit={submit}>
		<input
			bind:value={manager.draft}
			placeholder="Ask the manager"
			aria-label="Ask the manager"
			enterkeyhint="send"
			autocomplete="off"
			autocapitalize="sentences"
		/>
		{#if canSend}
			<button class="pill send grow" type="submit" disabled={manager.busy}>↑ Send</button>
		{:else}
			<button class="pill grow" type="button" disabled aria-disabled="true" aria-label="Talk"
				>🎙 Talk</button
			>
		{/if}
	</form>
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
		white-space: pre-wrap;
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

	.vrow {
		display: flex;
		align-items: center;
		gap: 8px;
	}

	.wave i {
		width: 3px;
		height: 5px;
		border-radius: 2px;
		background: #666;
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
</style>
