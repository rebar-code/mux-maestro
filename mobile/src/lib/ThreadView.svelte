<script lang="ts">
	import ArtifactInline from './ArtifactInline.svelte';
	import { inlineArtifacts } from './artifacts';
	import { ARTIFACTS, Artifacts } from './artifacts.svelte';
	import ArtifactsPage from './ArtifactsPage.svelte';
	import AttachButton from './AttachButton.svelte';
	import AttachTiles from './AttachTiles.svelte';
	import Composer from './Composer.svelte';
	import { Find } from './find.svelte';
	import FindBar from './FindBar.svelte';
	import type { Snippet } from 'svelte';
	import { dotClass, statusLabel } from './format';
	import { pages, pullToRefresh, ui } from './gestures.svelte';
	import KeyBar from './KeyBar.svelte';
	import { can, live, OFF_LABEL } from './live.svelte';
	import LiveTerminal from './LiveTerminal.svelte';
	import { LiveTerm } from './liveterm.svelte';
	import Marked from './Marked.svelte';
	import NextBar from './NextBar.svelte';
	import NoteLine from './NoteLine.svelte';
	import PromptCard from './PromptCard.svelte';
	import PullIndicator from './PullIndicator.svelte';
	import { push } from './push.svelte';
	import { liveLines, nextWaiting } from './reply';
	import { Reply } from './reply.svelte';
	import ServeConfirm from './ServeConfirm.svelte';
	import { SERVERS, Servers } from './servers.svelte';
	import ServersPage from './ServersPage.svelte';
	import SlashList from './SlashList.svelte';
	import { text } from './textsize.svelte';
	import { ThreadFeed, type Mode } from './thread.svelte';
	import type { ArtifactFile } from './types';
	import { voice } from './voice.svelte';
	import VoiceBar from './VoiceBar.svelte';

	interface Props {
		id: string;
		/**
		 * A feed that is not a listed thread's own (the manager pane). The view
		 * then has no thread row to read: it always has a chat and is never closed.
		 */
		feed?: ThreadFeed;
		/** Drawn in place of the thread's own toolbar. */
		header?: Snippet;
		/** Drawn after the last chat row: what the thread is doing now. */
		tail?: Snippet;
		/** A prompt that was sent and is not in the chat yet. */
		pending?: string | null;
		/** The first tab shows the terminal, not the chat. */
		terminal?: boolean;
		/**
		 * What asks and answers prompts on a pane that is not a listed thread
		 * (the manager). The view then draws the pane's prompt card; the page
		 * that gives it draws its own keys and text box.
		 */
		reply?: Reply;
	}

	/* eslint-disable prefer-const */
	// `terminal` is bound, so the props are one `let`.
	let {
		id,
		feed: given,
		header,
		tail,
		pending = null,
		terminal = $bindable(false),
		reply: givenReply
	}: Props = $props();
	/* eslint-enable prefer-const */

	const PULL = 'thread';
	const MAIN = 'main';
	// svelte-ignore state_referenced_locally
	const listed = given === undefined;
	// Files and servers belong to a listed thread. The manager pane is not one.
	const artifactsOn = $derived(listed && can('artifacts'));
	const serversOn = $derived(listed && can('localServers'));
	// The pages of this view, left to right. A tab whose feature is off on the
	// Mac is not there at all. Joined, so the same tabs are the same value and
	// a config that says nothing new does not send the pager back to Chat.
	const tabNames = $derived(
		[MAIN, ...(artifactsOn ? [ARTIFACTS] : []), ...(serversOn ? [SERVERS] : [])].join(' ')
	);
	const tabs = $derived(tabNames.split(' '));
	const LABELS: Record<string, string> = { [ARTIFACTS]: 'Artifacts', [SERVERS]: 'Servers' };

	// svelte-ignore state_referenced_locally
	const feed = given ?? new ThreadFeed(id);
	const thread = $derived(listed ? live.byId(id) : undefined);
	const canChat = $derived(listed ? (thread?.chat ?? false) : true);
	const mode: Mode = $derived(canChat && !terminal ? 'chat' : 'terminal');
	const closed = $derived(listed && ((live.threads !== null && !thread) || feed.gone));

	// svelte-ignore state_referenced_locally
	const artifacts = new Artifacts(id);
	// svelte-ignore state_referenced_locally
	const servers = new Servers(id);
	/** The files to draw in the chat, under the message that names each. */
	const inline = $derived(
		artifactsOn && feed.messages && artifacts.list
			? inlineArtifacts(feed.messages, artifacts.list.files)
			: null
	);

	function landed(index: number): void {
		artifacts.landed(index);
		servers.landed(index);
	}

	/** A tap on a file in the chat: the Artifacts tab slides in with it open. */
	function openInline(file: ArtifactFile): void {
		artifacts.show(file, 'chat');
		ui.goTo(tabs.indexOf(ARTIFACTS));
	}
	const color = $derived(thread?.hostColor ?? '#2a2a2a');

	// svelte-ignore state_referenced_locally
	const reply =
		givenReply ??
		new Reply(id, {
			refresh: () => feed.load(mode),
			stick: (change) => feed.keepEnd(mode, false, change),
			terminal: () => mode === 'terminal'
		});
	/** The pane's prompts are shown and answered here: a listed thread, or a pane given its own `reply`. */
	// svelte-ignore state_referenced_locally
	const asks = listed || givenReply !== undefined;

	// svelte-ignore state_referenced_locally
	const find = new Find(
		id,
		() => feed.messages ?? [],
		() => mode
	);
	const finding = $derived(find.open && can('find'));

	// svelte-ignore state_referenced_locally
	const term = new LiveTerm(id);
	// The manager's own pane is not a listed thread: it has no live terminal.
	const liveOn = $derived(listed && can('liveTerminal') && mode === 'terminal' && !closed);
	/** The pane's own screen is drawn: its keys go down the socket. */
	const liveShown = $derived(liveOn && term.active && term.shown);
	const LIVE_LABELS = {
		off: 'Live',
		connecting: 'Connecting',
		live: 'Live',
		reconnecting: 'Reconnecting'
	};

	const repliesOn = $derived(can('replies'));
	const keysOn = $derived(can('keyBar'));
	// A take goes to the thread as a reply, so voice needs that switch too.
	const voiceOn = $derived(repliesOn && can('voice'));
	// A listed thread's reply box is always there: switched off on the Mac, it says so and
	// takes nothing. The manager pane is not a listed thread: it has no reply routes, and
	// its page brings its own box, so it gets no dock, no card and no Next bar.
	const docked = $derived(listed && !closed);
	const next = $derived(listed && repliesOn ? nextWaiting(live.threads ?? [], id) : null);
	// The pane can ask while its status says nothing of it: the prompt decides.
	// With the key bar alone the card is read-only: it shows what a key would answer.
	const cardId = $derived(asks && (repliesOn || keysOn) ? reply.promptId : null);
	const card = $derived(cardId === null ? null : reply.prompt);

	/** The card shows only part of the pane's text: the terminal has it all. */
	function showTerminal(): void {
		// What a key was told before ("open the terminal") is done now.
		reply.note = null;
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
		if (index === 0 && ui.index === 0 && canChat) {
			terminal = !terminal;
			if (finding) find.switched(mode);
		}
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
		oncancel={repliesOn ? reply.cancel : undefined}
		{onterminal}
	/>
{/snippet}

{#if header}
	{@render header()}
{:else}
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
				<span
					><i class="hchip" style:background={color}>{thread.host}</i> {statusLabel(thread)}</span
				>
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
{/if}

{#if finding}<FindBar {find} />{/if}

<div class="tabs">
	<div class="seg" role="tablist">
		{#each tabs as tab, index (tab)}
			{#if tab === MAIN}
				<button
					class="grow"
					class:on={ui.index === index}
					role="tab"
					aria-selected={ui.index === index}
					aria-label={canChat ? `${mode === 'chat' ? 'Chat' : 'Terminal'}, switch` : 'Terminal'}
					data-tab={tab}
					data-mode={mode}
					onclick={() => selectTab(index)}
				>
					{mode === 'chat' ? 'Chat' : 'Terminal'}
					{#if canChat}<span class="swap">⇄</span>{/if}
				</button>
			{:else}
				<button
					class="grow"
					class:on={ui.index === index}
					role="tab"
					aria-selected={ui.index === index}
					data-tab={tab}
					onclick={() => selectTab(index)}>{LABELS[tab]}</button
				>
			{/if}
		{/each}
	</div>
	<button
		class="tb"
		aria-label="Refresh"
		disabled={ui.refreshing !== null}
		onclick={() => ui.refresh(ui.index === 0 ? PULL : tabs[ui.index])}>↻</button
	>
</div>

<div
	class="pager"
	class:docked
	data-thread-pages
	style:--term-size="{text.size}px"
	style:--chat-size="{text.chat}px"
	{@attach pages(tabs, landed)}
	{@attach feed.watch(mode)}
	{@attach listed && push.watching(id)}
	{@attach artifactsOn && artifacts.watch}
	{@attach serversOn && servers.watch}
	{@attach !listed && asks && (repliesOn || keysOn) && reply.watch}
>
	<div
		class="track"
		class:anim={!ui.dragging}
		style:transform="translate3d(calc({-ui.index * 100}% + {ui.dragX}px), 0, 0)"
	>
		{#each tabs as tab, index (tab)}
			<section class="page" inert={ui.index !== index} data-page={tab}>
				{#if closed}
					<div class="empty">Closed</div>
				{:else if tab === ARTIFACTS}
					<ArtifactsPage {artifacts} />
				{:else if tab === SERVERS}
					<ServersPage {servers} />
				{:else if mode === 'chat'}
					<div
						class="scroll"
						data-pull={PULL}
						data-view="chat"
						data-rise
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
									{#each inline?.get(message.n) ?? [] as file (file.id)}
										<ArtifactInline {file} {artifacts} onopen={openInline} />
									{/each}
								{/each}
								{#if reply.turn}
									{#if spoken.prompt}<div class="u" data-live>{reply.turn.prompt}</div>{/if}
									{#if spoken.reply}<div class="a" data-live>{reply.turn.reply}</div>{/if}
								{/if}
								{#if pending}
									<div class="u" data-pending>{pending}</div>
								{/if}
								{@render tail?.()}
							{/if}
							{#if cardId !== null}
								{@render promptCard(cardId, showTerminal)}
							{/if}
						</div>
					</div>
				{:else}
					{#if liveOn}
						<button
							class="livechip"
							class:on={term.active}
							aria-pressed={term.active}
							data-live={term.active ? term.state : 'off'}
							onclick={term.toggle}
						>
							<i></i>{term.active ? LIVE_LABELS[term.state] : (term.note ?? 'Live')}
						</button>
					{/if}
					{#if liveOn && term.active}
						<LiveTerminal {term} />
						{#if term.shown && !term.following}
							<button class="jump" aria-label="Jump to bottom" onclick={term.jump}>↓</button>
						{/if}
					{/if}
					{#if !liveShown}
						<div
							class="scroll"
							data-view="terminal"
							data-zoom
							data-rise
							{@attach feed.scroller('terminal')}
						>
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
							<button class="jump" aria-label="Jump to bottom" onclick={feed.jumpToBottom}>↓</button
							>
						{/if}
					{/if}
				{/if}
			</section>
		{/each}
	</div>
</div>

<ServeConfirm {servers} />

{#if docked}
	<div
		class="dock"
		data-dock
		{@attach (repliesOn || keysOn) && reply.watch}
		{@attach reply.files.watch}
	>
		{#if next}<NextBar thread={next} />{/if}
		{#if liveShown}
			<!-- The keyboard types into the pane itself: the bar is all it lacks. -->
			<div class="livebar"><KeyBar reply={term} composer /></div>
		{:else}
			{#if repliesOn && reply.matches.length}
				<SlashList commands={reply.matches} onpick={reply.pick} />
			{/if}
			{#if !repliesOn && reply.note}
				<!-- With no composer below, the bar's own refusals are said here. -->
				<NoteLine note={reply.note} />
			{/if}
			<!-- The voice status sits above the keys; its controls stay below them. -->
			{#if repliesOn && voiceOn && keysOn}
				<VoiceBar target={id} sink={reply.voice} part="status" />
			{/if}
			{#if keysOn}<KeyBar {reply} composer={repliesOn} />{/if}
			<!-- Voice switched off on the Mac: the bar stays and says so, like the manager's. -->
			{#if repliesOn}
				<VoiceBar
					target={id}
					sink={reply.voice}
					off={!voiceOn}
					part={voiceOn && keysOn ? 'controls' : 'all'}
				/>
			{/if}
			{#if repliesOn}
				<Composer
					bind:value={reply.draft}
					box={reply.box}
					label="Reply"
					target={id}
					sink={reply.voice}
					{voiceOn}
					blocked={reply.blocked || reply.files.pending}
					sending={reply.sending}
					note={reply.note}
					onsend={send}
					oninput={reply.typed}
					onbeforeinput={reply.beforeInput}
					onpaste={reply.pasted}
				>
					{#snippet above()}
						{#if reply.files.items.length}<AttachTiles files={reply.files} />{/if}
					{/snippet}
					{#snippet leading()}
						<AttachButton off={!can('upload')} onpick={reply.files.add} onoff={reply.uploadOff} />
					{/snippet}
				</Composer>
			{:else}
				<!-- Same box, same place: nothing moves when the Mac switches replies on. -->
				<Composer
					value=""
					label={OFF_LABEL}
					target={id}
					sink={reply.voice}
					voiceOn={false}
					off
					bare
					onsend={() => {}}
				>
					{#snippet leading()}
						<AttachButton disabled />
					{/snippet}
				</Composer>
			{/if}
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
		/* `clip`, not `hidden`: the row of pages must never scroll by itself. */
		overflow: clip;
	}

	.track {
		display: flex;
		height: 100%;
		will-change: transform;
	}

	.track.anim {
		transition: transform 0.26s var(--ease);
	}

	/* A mouse that drags the page must not select the text it passes over. */
	.track:not(.anim) {
		-webkit-user-select: none;
		user-select: none;
	}

	.page {
		flex: 0 0 100%;
		min-width: 0;
		display: flex;
		flex-direction: column;
		height: 100%;
		/* An open file lies over its page. */
		position: relative;
	}

	.chat {
		display: flex;
		flex-direction: column;
		gap: 10px;
		padding: 10px 14px calc(16px + var(--below, env(safe-area-inset-bottom)));
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
	}

	/*
	 * With the keyboard up the screen is short: what is not for typing gives
	 * its room to the chat and the text box.
	 */
	:global([data-kb]) .dock :global(:is(.next, .vbar.off)) {
		display: none;
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
		padding: 10px 12px calc(16px + var(--below, env(safe-area-inset-bottom)));
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

	/* Find draws the scrollback as plain text in the same box. */
	pre.screen {
		margin: 0;
		white-space: pre;
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
		bottom: calc(14px + var(--below, env(safe-area-inset-bottom)));
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

	/* The live switch: over the terminal's top right corner. */
	.livechip {
		position: absolute;
		z-index: 2;
		top: 6px;
		right: max(8px, env(safe-area-inset-right));
		min-height: var(--hit);
		min-width: var(--hit);
		display: flex;
		align-items: center;
		gap: 7px;
		padding: 0 12px;
		border-radius: 22px;
		background: var(--surface);
		border: 1px solid var(--border);
		font-size: 13px;
		color: var(--muted);
	}

	.livechip.on {
		color: #ededed;
	}

	.livechip i {
		width: 8px;
		height: 8px;
		border-radius: 50%;
		background: var(--muted);
	}

	.livechip[data-live='live'] i {
		background: var(--green);
	}

	.livechip[data-live='connecting'] i,
	.livechip[data-live='reconnecting'] i {
		background: var(--amber);
	}

	/* Nothing below the bar in live mode: it keeps clear of the home indicator. */
	.livebar {
		padding-bottom: var(--safe-bottom, env(safe-area-inset-bottom));
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
