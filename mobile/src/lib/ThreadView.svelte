<script lang="ts">
	import { dotClass, statusLabel } from './format';
	import { pages, pullToRefresh, ui } from './gestures.svelte';
	import { live } from './live.svelte';
	import PullIndicator from './PullIndicator.svelte';
	import { ThreadFeed, type Mode } from './thread.svelte';

	const { id }: { id: string } = $props();

	const PULL = 'thread';
	// The pages of this view, left to right. A later tab is one more entry here
	// and one more `{:else if}` in the pager below.
	const TABS = [{ key: 'main' }] as const;
	const TAB_KEYS = TABS.map((tab) => tab.key);

	// svelte-ignore state_referenced_locally
	const feed = new ThreadFeed(id);

	const thread = $derived(live.byId(id));
	const canChat = $derived(thread?.chat ?? false);
	let terminal = $state(false);
	const mode: Mode = $derived(canChat && !terminal ? 'chat' : 'terminal');
	const closed = $derived((live.threads !== null && !thread) || feed.gone);
	const color = $derived(thread?.hostColor ?? '#2a2a2a');

	function selectTab(index: number): void {
		// The first tab is also a switch: a tap while it is showing flips the
		// page between the chat and the pane's terminal.
		if (index === 0 && ui.index === 0 && canChat) terminal = !terminal;
		ui.goTo(index);
	}
</script>

<header
	class="tbar thread"
	style:border-bottom-color={color}
	style:background="linear-gradient({color}3a, {color}14), var(--bar)"
>
	<button class="tb" aria-label="Menu" onclick={() => ui.openDrawer()}>☰</button>
	{#if thread}
		<span class="dot {dotClass(thread)}"></span>
		<div class="title">
			<b>{thread.session} · {thread.name}</b>
			<span><i class="hchip" style:background={color}>{thread.host}</i> {statusLabel(thread)}</span>
		</div>
	{:else if closed}
		<div class="title"><b>Closed</b></div>
	{:else}
		<div class="title">
			<span class="skel" style:width="55%" style:height="14px" style:margin-bottom="5px"></span>
			<span class="skel" style:width="35%" style:height="11px"></span>
		</div>
	{/if}
	<button class="tb" disabled aria-disabled="true" aria-label="Find">🔍</button>
</header>

<div class="tabs">
	<div class="seg" role="tablist">
		{#each TABS as tab, index (tab.key)}
			<button
				class="grow"
				class:on={ui.index === index}
				role="tab"
				aria-selected={ui.index === index}
				aria-label={canChat ? `${mode === 'chat' ? 'Chat' : 'Terminal'}, switch` : 'Terminal'}
				data-tab={tab.key}
				data-mode={mode}
				onclick={() => selectTab(index)}
			>
				{mode === 'chat' ? 'Chat' : 'Terminal'}
				{#if canChat}<span class="swap">⇄</span>{/if}
			</button>
		{/each}
	</div>
	<button
		class="tb"
		aria-label="Refresh"
		disabled={ui.refreshing !== null}
		onclick={() => ui.refresh(PULL)}>↻</button
	>
</div>

<div class="pager" {@attach pages(TAB_KEYS)} {@attach feed.watch(mode)}>
	<div
		class="track"
		class:anim={!ui.dragging}
		style:transform="translate3d(calc({-ui.index * 100}% + {ui.dragX}px), 0, 0)"
	>
		{#each TABS as tab, index (tab.key)}
			<section class="page" inert={ui.index !== index} data-page={tab.key}>
				{#if closed}
					<div class="empty">Closed</div>
				{:else if mode === 'chat'}
					<div
						class="scroll"
						data-pull={PULL}
						data-view="chat"
						{@attach feed.scroller('chat')}
						{@attach pullToRefresh(PULL, () => feed.load('chat'))}
					>
						<PullIndicator key={PULL} />
						<div class="chat">
							{#if feed.messages === null}
								{#each [62, 88, 74, 40] as width (width)}
									<span class="skel" style:width="{width}%" style:height="16px"></span>
								{/each}
							{:else}
								{#each feed.messages as message (message.n)}
									{#if message.role === 'user'}
										<div class="u">{message.text}</div>
									{:else if message.role === 'assistant'}
										<div class="a">{message.text}</div>
									{:else}
										<div class="tool"><b>{message.tool}</b> {message.text}</div>
									{/if}
								{/each}
							{/if}
						</div>
					</div>
				{:else}
					<div
						class="scroll"
						data-pull={PULL}
						data-view="terminal"
						{@attach feed.scroller('terminal')}
						{@attach pullToRefresh(PULL, () => feed.load('terminal'))}
					>
						<PullIndicator key={PULL} />
						{#if feed.screen === null}
							<div class="chat">
								{#each [90, 70, 82, 55, 76] as width (width)}
									<span class="skel" style:width="{width}%" style:height="11px"></span>
								{/each}
							</div>
						{:else}
							<pre class="screen mono" data-hscroll>{feed.screen}</pre>
						{/if}
					</div>
				{/if}
			</section>
		{/each}
	</div>
</div>

<style>
	.thread {
		border-bottom-width: 2px;
	}

	.thread .dot {
		margin: 0;
	}

	.hchip {
		font-style: normal;
		color: #000;
		font-weight: 600;
		border-radius: 5px;
		padding: 0 6px;
		font-size: 11px;
	}

	.tabs {
		display: flex;
		align-items: center;
		flex: none;
		padding-right: 8px;
	}

	.tabs .seg {
		flex: 1;
		margin-right: 8px;
	}

	.seg button {
		display: flex;
		justify-content: center;
		gap: 7px;
	}

	.swap {
		color: var(--muted);
	}

	.pager {
		flex: 1;
		min-height: 0;
		overflow: hidden;
	}

	.track {
		display: flex;
		height: 100%;
		will-change: transform;
	}

	.track.anim {
		transition: transform 0.26s var(--ease);
	}

	.page {
		flex: 0 0 100%;
		min-width: 0;
		display: flex;
		flex-direction: column;
		height: 100%;
	}

	.chat {
		display: flex;
		flex-direction: column;
		gap: 10px;
		padding: 10px 14px calc(16px + env(safe-area-inset-bottom));
	}

	.u {
		align-self: flex-end;
		max-width: 86%;
		background: #1d2b40;
		border-radius: 16px 16px 4px 16px;
		padding: 8px 12px;
		white-space: pre-wrap;
		overflow-wrap: anywhere;
	}

	.a {
		max-width: 94%;
		color: #e2e2e2;
		white-space: pre-wrap;
		overflow-wrap: anywhere;
	}

	.tool {
		font-size: 12.5px;
		color: var(--muted);
		border-left: 2px solid var(--border);
		padding: 1px 0 1px 9px;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.tool b {
		color: #b8b8b8;
		font-weight: 600;
	}

	.screen {
		margin: 0;
		padding: 10px 12px calc(16px + env(safe-area-inset-bottom));
		font-size: 11px;
		line-height: 1.3;
		color: #cfcfcf;
		white-space: pre;
		/* Moved by the gesture controller, so it can hand over to the drawer at its edge. */
		overflow-x: hidden;
		min-height: 100%;
	}

	.empty {
		display: flex;
		align-items: center;
		justify-content: center;
		height: 100%;
		color: var(--muted);
	}
</style>
