<script lang="ts">
	import AttachButton from './AttachButton.svelte';
	import Composer from './Composer.svelte';
	import { Find } from './find.svelte';
	import FindBar from './FindBar.svelte';
	import { dotClass, statusLabel } from './format';
	import { pages, pullToRefresh, ui } from './gestures.svelte';
	import KeyBar from './KeyBar.svelte';
	import { overKeyboard } from './keyboard';
	import { can, live } from './live.svelte';
	import Marked from './Marked.svelte';
	import NextBar from './NextBar.svelte';
	import PromptCard from './PromptCard.svelte';
	import PullIndicator from './PullIndicator.svelte';
	import { liveLines, nextWaiting } from './reply';
	import { Reply } from './reply.svelte';
	import SlashList from './SlashList.svelte';
	import { ThreadFeed, type Mode } from './thread.svelte';
	import { voice } from './voice.svelte';
	import VoiceBar from './VoiceBar.svelte';

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

	// svelte-ignore state_referenced_locally
	const reply = new Reply(id, {
		refresh: () => feed.load(mode),
		stick: (change) => feed.keepEnd(mode, false, change)
	});

	// svelte-ignore state_referenced_locally
	const find = new Find(
		id,
		() => feed.messages ?? [],
		() => mode
	);
	const finding = $derived(find.open && can('find'));

	const repliesOn = $derived(can('replies'));
	const keysOn = $derived(can('keyBar'));
	// A take goes to the thread as a reply, so voice needs that switch too.
	const voiceOn = $derived(repliesOn && can('voice'));
	const docked = $derived(!closed && (repliesOn || keysOn));
	const next = $derived(repliesOn ? nextWaiting(live.threads ?? [], id) : null);
	const card = $derived(repliesOn && thread?.status === 'waiting' ? reply.prompt : null);
	const spoken = $derived(liveLines(feed.messages ?? [], reply.turn));

	function send(): void {
		// A typed reply takes over: a reply that is still being read stops.
		if (voiceOn) voice.skip();
		void reply.send();
	}

	function selectTab(index: number): void {
		// The first tab is also a switch: a tap while it is showing flips the
		// page between the chat and the pane's terminal.
		if (index === 0 && ui.index === 0 && canChat) {
			terminal = !terminal;
			if (finding) find.switched(mode);
		}
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
	<button
		class="tb"
		disabled={!can('find') || closed}
		aria-disabled={!can('find')}
		aria-label="Find"
		aria-pressed={finding}
		onclick={find.toggle}>🔍</button
	>
</header>

{#if finding}<FindBar {find} />{/if}

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

<div class="pager" class:docked {@attach pages(TAB_KEYS)} {@attach feed.watch(mode)}>
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
									{@const hits = finding ? find.chat.byRow.get(message.n) : undefined}
									{#snippet body()}
										{#if hits}
											<Marked text={message.text} {hits} current={find.current} />
										{:else}
											{message.text}
										{/if}
									{/snippet}
									{#if message.role === 'user'}
										<div class="u">{@render body()}</div>
									{:else if message.role === 'assistant'}
										<div class="a">{@render body()}</div>
									{:else}
										<div class="tool"><b>{message.tool}</b> {@render body()}</div>
									{/if}
								{/each}
								{#if reply.turn}
									{#if spoken.prompt}<div class="u" data-live>{reply.turn.prompt}</div>{/if}
									{#if spoken.reply}<div class="a" data-live>{reply.turn.reply}</div>{/if}
								{/if}
							{/if}
							{#if card}
								<PromptCard prompt={card} answering={reply.answering} onanswer={reply.answer} />
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
						{:else if finding && find.result}
							<!-- The pane's scrollback, as the Mac searched it. -->
							<pre class="screen mono" data-hscroll data-find-text><Marked
									text={find.result.text}
									hits={find.terminal}
									current={find.current}
								/></pre>
						{:else}
							<pre class="screen mono" class:carded={card !== null} data-hscroll>{feed.screen}</pre>
						{/if}
						{#if card}
							<div class="chat">
								<PromptCard prompt={card} answering={reply.answering} onanswer={reply.answer} />
							</div>
						{/if}
					</div>
				{/if}
			</section>
		{/each}
	</div>
</div>

{#if docked}
	<div class="dock" data-dock {@attach overKeyboard} {@attach repliesOn && reply.watch}>
		{#if next}<NextBar thread={next} />{/if}
		{#if repliesOn && reply.matches.length}
			<SlashList commands={reply.matches} onpick={reply.pick} />
		{/if}
		{#if keysOn}<KeyBar {reply} composer={repliesOn} />{/if}
		{#if voiceOn}<VoiceBar target={id} sink={reply.voice} />{/if}
		{#if repliesOn}
			<Composer
				bind:value={reply.draft}
				box={reply.box}
				label="Reply"
				target={id}
				sink={reply.voice}
				{voiceOn}
				blocked={reply.blocked || reply.sending}
				note={reply.note}
				onsend={send}
				oninput={reply.typed}
				onbeforeinput={reply.beforeInput}
			>
				{#snippet leading()}
					{#if can('upload')}
						<AttachButton busy={reply.uploading} disabled={reply.blocked} onpick={reply.upload} />
					{/if}
				{/snippet}
			</Composer>
		{/if}
	</div>
{/if}

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

	/* The bar below keeps clear of the home indicator. */
	.docked .chat,
	.docked .screen {
		padding-bottom: 16px;
	}

	.dock {
		flex: none;
		display: flex;
		flex-direction: column;
		padding-bottom: var(--kb, 0px);
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
		padding-bottom: 6px;
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

	/* The card under it has to be on screen. */
	.screen.carded {
		min-height: 0;
	}

	.empty {
		display: flex;
		align-items: center;
		justify-content: center;
		height: 100%;
		color: var(--muted);
	}
</style>
