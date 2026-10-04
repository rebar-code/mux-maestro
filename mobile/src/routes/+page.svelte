<script lang="ts">
	import { resolve } from '$app/paths';
	import { age } from '$lib/format';
	import { pullToRefresh, ui } from '$lib/gestures.svelte';
	import { counts } from '$lib/group';
	import { can, live } from '$lib/live.svelte';
	import { maestro } from '$lib/maestro.svelte';
	import MaestroInput from '$lib/MaestroInput.svelte';
	import MaestroTail from '$lib/MaestroTail.svelte';
	import { needsYouCards } from '$lib/manager';
	import { manager } from '$lib/manager.svelte';
	import PullIndicator from '$lib/PullIndicator.svelte';
	import TalkButton from '$lib/TalkButton.svelte';
	import ThreadView from '$lib/ThreadView.svelte';

	const PULL = 'home';

	const tally = $derived(live.threads ? counts(live.threads) : null);
	const managerOn = $derived(can('manager'));
	const waiting = $derived(needsYouCards(live.threads ?? [], []));
	// The Maestro pane's prompts and keys: the same ones the panel shows.
	const reply = maestro.reply;
</script>

{#snippet header()}
	<header class="tbar" data-maestro-grab>
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

{#snippet tail()}
	<MaestroTail onterminal={() => (maestro.terminal = true)} />
{/snippet}

{#if managerOn}
	<div class="stage">
		<ThreadView
			id="manager"
			feed={manager.feed}
			{header}
			{tail}
			pending={manager.pending}
			{reply}
			bind:terminal={maestro.terminal}
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
	The footer: the text box, the same on every page. The board is a tab of the
	thread above it. With the Manager switch off the box stays, disabled, and
	says where the switch is.
-->
<div class="foot" class:bare={!managerOn} data-foot>
	<MaestroInput />
</div>

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

	/* The footer draws the top edge and the background: the text box row draws neither. */
	.foot.bare :global(.compose) {
		padding-top: 8px;
	}

	/* The manager's thread, above the footer. */
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

	/* The footer draws the top edge: the voice bar in it draws none. */
	.foot :global(.vbar) {
		border-top: 0;
		background: none;
	}
</style>
