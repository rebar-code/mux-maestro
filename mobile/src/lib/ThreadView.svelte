<script lang="ts">
	import AttachButton from './AttachButton.svelte';
	import Composer from './Composer.svelte';
	import { dotClass, statusLabel } from './format';
	import { pages, pullToRefresh, ui } from './gestures.svelte';
	import KeyBar from './KeyBar.svelte';
	import { overKeyboard } from './keyboard';
	import { can, live } from './live.svelte';
	import NextBar from './NextBar.svelte';
	import PromptCard from './PromptCard.svelte';
	import PullIndicator from './PullIndicator.svelte';
	import { liveLines, nextWaiting } from './reply';
	import { Reply } from './reply.svelte';
	import SlashList from './SlashList.svelte';
	import { text } from './textsize.svelte';
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

	const repliesOn = $derived(can('replies'));
	const keysOn = $derived(can('keyBar'));
	// A take goes to the thread as a reply, so voice needs that switch too.
	const voiceOn = $derived(repliesOn && can('voice'));
	const docked = $derived(!closed && (repliesOn || keysOn));
	const next = $derived(repliesOn ? nextWaiting(live.threads ?? [], id) : null);
	// The pane can ask while its status says nothing of it: the prompt decides.
	// With the key bar alone the card is read-only: it shows what a key would answer.
	const cardId = $derived(repliesOn || keysOn ? reply.promptId : null);
	const card = $derived(cardId === null ? null : reply.prompt);

	/** The card shows only part of the pane's text: the terminal has it all. */
	function showTerminal(): void {
		terminal = true;
		ui.goTo(0);
	}
	const spoken = $derived(liveLines(feed.messages ?? [], reply.turn));

	function send(): void {
		// A typed reply takes over: a reply that is still being read stops.
		if (voiceOn) voice.skip();
		void reply.send();
	}

	function selectTab(index: number): void {
		// The first tab is also a switch: a tap while it is showing flips the
		// page between the chat and the pane's terminal.
		if (index === 0 && ui.index === 0 && canChat) terminal = !terminal;
		ui.goTo(index);
	}
</script>

{#snippet promptCard(shown: string, onterminal?: () => void)}
	<PromptCard
		id={shown}
		prompt={card}
		readonly={!repliesOn}
		answering={reply.answering}
		onanswer={reply.answer}
		{onterminal}
	/>
{/snippet}

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
		class="tb size"
		aria-label="Smaller text"
		disabled={text.atMin}
		onclick={() => text.step(-1)}>A−</button
	>
	<button
		class="tb size"
		aria-label="Larger text"
		disabled={text.atMax}
		onclick={() => text.step(1)}>A+</button
	>
	<button
		class="tb"
		aria-label="Refresh"
		disabled={ui.refreshing !== null}
		onclick={() => ui.refresh(PULL)}>↻</button
	>
</div>

<div
	class="pager"
	class:docked
	style:--term-size="{text.size}px"
	style:--chat-size="{text.chat}px"
	{@attach pages(TAB_KEYS)}
	{@attach feed.watch(mode)}
>
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
								{#if reply.turn}
									{#if spoken.prompt}<div class="u" data-live>{reply.turn.prompt}</div>{/if}
									{#if spoken.reply}<div class="a" data-live>{reply.turn.reply}</div>{/if}
								{/if}
							{/if}
							{#if cardId !== null}
								{@render promptCard(cardId, showTerminal)}
							{/if}
						</div>
					</div>
				{:else}
					<div class="scroll" data-view="terminal" data-zoom {@attach feed.scroller('terminal')}>
						{#if feed.screen === null}
							<div class="chat">
								{#each [90, 70, 82, 55, 76] as width (width)}
									<span class="skel" style:width="{width}%" style:height="11px"></span>
								{/each}
							</div>
						{:else}
							{#if feed.screen.hasOlder}
								<button class="older" disabled={feed.loadingOlder} onclick={feed.loadOlder}>
									Load older
								</button>
							{/if}
							<div class="screen mono" data-hscroll>
								<div class="lines" data-lines style:min-width="{feed.screen.cols}ch">
									{#each feed.screen.blocks as block (block.key)}
										<div class="blk" style:--n={block.lines.length}>
											{#each block.lines as line (line.n)}
												<div class="ln">
													{#each line.spans as span, at (at)}
														<span
															class:sb={span.bold}
															class:sd={span.dim}
															class:si={span.italic}
															class:su={span.underline}
															style:color={span.color}
															style:background-color={span.background}>{span.text}</span
														>
													{/each}
												</div>
											{/each}
										</div>
									{/each}
								</div>
							</div>
						{/if}
						{#if cardId !== null}
							<div class="chat">{@render promptCard(cardId)}</div>
						{/if}
					</div>
					{#if !feed.atBottom}
						<button class="jump" aria-label="Jump to bottom" onclick={feed.jumpToBottom}>↓</button>
					{/if}
				{/if}
			</section>
		{/each}
	</div>
</div>

{#if docked}
	<div class="dock" data-dock {@attach overKeyboard} {@attach reply.watch}>
		{#if next}<NextBar thread={next} />{/if}
		{#if repliesOn && reply.matches.length}
			<SlashList commands={reply.matches} onpick={reply.pick} />
		{/if}
		{#if !repliesOn && reply.note}
			<!-- With no composer below, the bar's own refusals are said here. -->
			<div class="knote" class:bad={reply.note.bad} role="alert" data-note>{reply.note.text}</div>
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
		gap: 8px;
		padding-right: 8px;
	}

	.tabs .seg {
		flex: 1;
		margin-right: 0;
	}

	.size {
		font-size: 14px;
		font-weight: 600;
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
		font-size: var(--chat-size);
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

	.knote {
		padding: 0 max(18px, env(safe-area-inset-right)) 6px max(18px, env(safe-area-inset-left));
		font-size: 12.5px;
		color: var(--muted);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.knote.bad {
		color: var(--red);
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
		/* 12.5px beside 15px text. */
		font-size: 0.8333em;
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

	/* The feed keeps the view in place itself; the browser must not also try. */
	[data-view='terminal'] {
		overflow-anchor: none;
		display: flex;
		flex-direction: column;
	}

	.screen {
		padding: 10px 12px calc(16px + env(safe-area-inset-bottom));
		font-size: var(--term-size);
		/* A whole number of pixels, so a thousand lines are exactly a thousand times one. */
		--lh: calc(var(--term-size) * 1.3);
		line-height: var(--lh);
		color: #cfcfcf;
		/* Moved by the gesture controller, so it can hand over to the drawer at its edge. */
		overflow-x: hidden;
		/* Fills the page when the text is short, so a drag below the text still lands on it. */
		flex: 1 0 auto;
	}

	@supports (width: round(1.5px, 1px)) {
		.screen {
			--lh: round(calc(var(--term-size) * 1.3), 1px);
		}
	}

	/* A run of lines the browser may skip while it is off screen. */
	.blk {
		content-visibility: auto;
		/*
		 * Exact, because every line is the same height. No `auto`: a remembered
		 * height would be wrong as soon as the block gains or loses lines.
		 */
		contain-intrinsic-height: calc(var(--n) * var(--lh));
	}

	/*
	 * One terminal line. A flex row, so the only text in it is the spans': no
	 * stray space from the markup can get between them.
	 */
	.ln {
		display: flex;
		height: var(--lh);
	}

	.ln span {
		flex: none;
		white-space: pre;
	}

	.sb {
		font-weight: 700;
	}

	.sd {
		opacity: 0.6;
	}

	.si {
		font-style: italic;
	}

	.su {
		text-decoration: underline;
	}

	.older {
		display: block;
		min-height: var(--hit);
		margin: 8px auto 0;
		padding: 0 18px;
		border-radius: 22px;
		background: var(--surface);
		border: 1px solid var(--border);
		font-size: 14px;
		color: var(--accent);
	}

	.page {
		position: relative;
	}

	.jump {
		position: absolute;
		right: max(12px, env(safe-area-inset-right));
		bottom: calc(14px + env(safe-area-inset-bottom));
		width: var(--hit);
		height: var(--hit);
		border-radius: 50%;
		background: var(--surface);
		border: 1px solid var(--border);
		box-shadow: 0 4px 14px rgba(0, 0, 0, 0.5);
		font-size: 18px;
	}

	.docked .jump {
		bottom: 14px;
	}

	.jump:active {
		filter: brightness(1.4);
	}

	.empty {
		display: flex;
		align-items: center;
		justify-content: center;
		height: 100%;
		color: var(--muted);
	}
</style>
