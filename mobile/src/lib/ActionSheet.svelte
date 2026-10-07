<script lang="ts">
	import {
		folderName,
		killWarning,
		menuItems,
		menuTitle,
		NAME_MAX,
		START_ITEMS,
		startTitle
	} from './actions';
	import { menu } from './actions.svelte';
	import { shortCwd } from './format';
	import { can } from './live.svelte';

	const CLOSE_AT = 80;
	const SLOP = 8;

	const target = $derived(menu.target);
	const title = $derived(target ? menuTitle(target) : '');
	const items = $derived(target ? menuItems(target, can('kill')) : []);
	/** Where the new session starts, as the sheet names it. */
	const place = $derived(menu.dir ? shortCwd(menu.dir) : 'Home');
	const agentLabel = $derived(START_ITEMS.find((item) => item.kind === menu.agent)?.label ?? '');

	/** How far a finger has pulled the sheet down. */
	let pulled = $state(0);
	let dragging = $state(false);
	let start: { id: number; y: number } | null = null;
	let moved = false;

	function onpointerdown(event: PointerEvent): void {
		moved = false;
		// A list that scrolls keeps its own drags; so does the text box.
		if (!event.isPrimary || (event.target as Element).closest('[data-own-drag], input, textarea'))
			return;
		start = { id: event.pointerId, y: event.clientY };
	}

	function onpointermove(event: PointerEvent): void {
		if (!start || event.pointerId !== start.id) return;
		const dy = event.clientY - start.y;
		if (!dragging) {
			if (Math.abs(dy) < SLOP) return;
			dragging = true;
			moved = true;
			(event.currentTarget as HTMLElement).setPointerCapture(start.id);
		}
		pulled = Math.max(dy, 0);
	}

	function onpointerup(event: PointerEvent): void {
		if (!start || event.pointerId !== start.id) return;
		start = null;
		if (!dragging) return;
		dragging = false;
		if (pulled >= CLOSE_AT && event.type === 'pointerup') menu.close();
		pulled = 0;
	}

	// A pull that ends over a button must not also tap it.
	function onclickcapture(event: MouseEvent): void {
		if (!moved) return;
		moved = false;
		event.preventDefault();
		event.stopPropagation();
	}

	function onkeydown(event: KeyboardEvent): void {
		if (target && event.key === 'Escape') menu.close();
	}

	function submit(event: SubmitEvent): void {
		event.preventDefault();
		void menu.rename();
	}

	function startSession(event: SubmitEvent): void {
		event.preventDefault();
		void menu.newSession(menu.agent);
	}
</script>

<svelte:window {onkeydown} />

{#if target}
	<button class="scrim" aria-label="Close menu" onclick={menu.close}></button>
	<div
		class="sheet"
		class:anim={!dragging}
		role="dialog"
		aria-modal="true"
		aria-label={title}
		tabindex="-1"
		data-action-sheet={menu.stage}
		style:transform="translate3d(0, {pulled}px, 0)"
		{onpointerdown}
		{onpointermove}
		{onpointerup}
		onpointercancel={onpointerup}
		{onclickcapture}
	>
		<div class="grab" aria-hidden="true"><i></i></div>

		{#if menu.stage === 'menu'}
			<div class="title">{title}</div>
			{#each items as item (item.key)}
				<button
					class="item"
					class:danger={item.danger}
					disabled={menu.busy}
					onclick={() => menu.pick(item.key)}>{item.label}</button
				>
			{/each}
		{:else if menu.stage === 'rename'}
			<div class="title">Rename {title}</div>
			<form onsubmit={submit}>
				<input
					type="text"
					enterkeyhint="done"
					autocomplete="off"
					autocapitalize="off"
					autocorrect="off"
					spellcheck="false"
					maxlength={NAME_MAX}
					aria-label="Name"
					aria-invalid={!menu.nameOk}
					bind:value={menu.name}
					{@attach (node) => {
						node.focus();
						node.select();
					}}
				/>
				<button class="item go" type="submit" disabled={menu.busy || !menu.nameOk}>Rename</button>
			</form>
			<button class="item" onclick={menu.close}>Cancel</button>
		{:else if menu.stage === 'kill'}
			<div class="title strong">Kill “{title}”?</div>
			<p class="warn">{killWarning(menu.killKind)}</p>
			<button class="item danger" disabled={menu.busy} onclick={() => menu.kill()}>Kill</button>
			<button class="item" onclick={menu.close}>Cancel</button>
		{:else if menu.stage === 'start'}
			<div class="title">New window in {target ? startTitle(target) : ''}</div>
			{#each START_ITEMS as item (item.kind)}
				<button
					class="item"
					disabled={menu.busy}
					data-start={item.kind}
					onclick={() => menu.newWindow(item.kind)}>{item.label}</button
				>
			{/each}
		{:else if menu.stage === 'agent'}
			<div class="title">New session in {place}</div>
			{#each START_ITEMS as item (item.kind)}
				<button
					class="item"
					disabled={menu.busy}
					data-start={item.kind}
					onclick={() => menu.pickAgent(item.kind)}>{item.label}</button
				>
			{/each}
		{:else if menu.stage === 'prompt'}
			<div class="title">{agentLabel} in {place}</div>
			<form onsubmit={startSession}>
				<textarea
					rows="3"
					enterkeyhint="enter"
					autocomplete="off"
					autocapitalize="sentences"
					placeholder="Prompt"
					aria-label="Prompt"
					aria-invalid={!menu.promptOk}
					bind:value={menu.prompt}
					{@attach (node) => node.focus()}></textarea>
				<button class="item go" type="submit" disabled={menu.busy || !menu.promptOk}>Start</button>
			</form>
			<button class="item" onclick={menu.close}>Cancel</button>
		{:else}
			{@const folder = menu.folder}
			<div class="title">New session on {title}</div>
			{#if folder}
				<div class="where mono" data-folder={folder.path}>{shortCwd(folder.path)}</div>
			{/if}
			<div class="list" data-own-drag>
				{#if menu.dirs === null && !menu.error}
					<div class="item"><span class="skel" style:width="60%" style:height="14px"></span></div>
				{:else if folder}
					<button class="item" disabled={menu.loading} data-up onclick={menu.up}>Up</button>
					{#each menu.dirs ?? [] as dir (dir)}
						<button
							class="item mono"
							disabled={menu.loading}
							data-dir={dir}
							onclick={() => menu.browse(dir)}>{folderName(dir)}</button
						>
					{/each}
				{:else}
					{#each menu.dirs ?? [] as dir (dir)}
						<button
							class="item mono"
							disabled={menu.loading}
							data-dir={dir}
							onclick={() => menu.choose(dir)}>{shortCwd(dir)}</button
						>
					{/each}
					{#if menu.home}
						<button
							class="item"
							disabled={menu.loading}
							data-browse
							onclick={() => menu.browse(menu.home)}>Browse…</button
						>
					{/if}
					<button class="item" disabled={menu.loading} onclick={() => menu.choose(null)}
						>Home</button
					>
				{/if}
			</div>
			{#if folder}
				<button
					class="item go"
					disabled={menu.loading}
					data-use
					onclick={() => menu.choose(folder.path)}>Use this folder</button
				>
			{/if}
		{/if}

		{#if menu.error}<div class="error" role="alert">{menu.error}</div>{/if}
	</div>
{/if}

<style>
	.scrim {
		position: absolute;
		inset: 0;
		z-index: 50;
		width: 100%;
		border-radius: 0;
		background: rgba(0, 0, 0, 0.55);
		animation: fade 0.18s ease-out;
	}

	.sheet {
		position: absolute;
		left: max(8px, env(safe-area-inset-left));
		right: max(8px, env(safe-area-inset-right));
		/* The app is already as tall as what the keyboard leaves: the sheet only clears the home indicator. */
		bottom: calc(8px + var(--safe-bottom, env(safe-area-inset-bottom)));
		z-index: 51;
		display: flex;
		flex-direction: column;
		max-height: 70%;
		background: #1c1c1e;
		border-radius: 14px;
		overflow: hidden;
		animation: up 0.18s ease-out;
		outline: none;
	}

	.sheet.anim {
		transition: transform 0.2s var(--ease);
	}

	/* The sheet follows a finger down; the browser must not take the drag. */
	/* `!important`: the app root sets `pan-y` on every element with the same weight. */
	.sheet,
	.sheet :global(*) {
		touch-action: none !important;
	}

	.sheet .list,
	.sheet .list :global(*) {
		touch-action: pan-y !important;
	}

	@keyframes up {
		from {
			transform: translateY(40%);
			opacity: 0;
		}
	}

	@keyframes fade {
		from {
			opacity: 0;
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.sheet,
		.scrim {
			animation: none;
		}

		.sheet.anim {
			transition: none;
		}
	}

	.grab {
		display: flex;
		justify-content: center;
		padding: 7px 0 0;
	}

	.grab i {
		width: 36px;
		height: 4px;
		border-radius: 2px;
		background: #48484a;
	}

	.title {
		padding: 8px 16px 10px;
		font-size: 12px;
		color: var(--muted);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
		-webkit-user-select: none;
		user-select: none;
	}

	.title.strong {
		font-size: 16px;
		font-weight: 600;
		color: var(--text);
		padding-bottom: 4px;
	}

	.warn {
		margin: 0;
		padding: 0 16px 12px;
		font-size: 13.5px;
		color: var(--muted);
	}

	.list {
		overflow-y: auto;
		overscroll-behavior: contain;
		min-height: 0;
	}

	.item {
		display: flex;
		align-items: center;
		flex: none;
		width: 100%;
		min-height: 50px;
		padding: 0 16px;
		text-align: left;
		border-top: 1px solid #2c2c2e;
		font-size: 16px;
	}

	.item.mono {
		font-size: 14px;
	}

	.item:not(:disabled):active {
		background: #2c2c2e;
	}

	.danger {
		color: var(--red);
	}

	.go {
		color: var(--accent);
		font-weight: 600;
	}

	form {
		display: flex;
		flex-direction: column;
	}

	.where {
		padding: 0 16px 10px;
		font-size: 14px;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	input,
	textarea {
		margin: 0 12px 12px;
		height: 46px;
		background: var(--bg);
		border: 1px solid var(--border);
		border-radius: 10px;
		padding: 0 12px;
		color: var(--text);
		font: inherit;
		/* Under 16px, iOS zooms the page when the box takes focus. */
		font-size: 16px;
		outline: none;
	}

	textarea {
		height: auto;
		padding: 10px 12px;
		resize: none;
	}

	input:focus,
	textarea:focus {
		border-color: var(--accent);
	}

	input[aria-invalid='true'],
	textarea[aria-invalid='true'] {
		border-color: var(--red);
	}

	.error {
		padding: 10px 16px 12px;
		border-top: 1px solid #2c2c2e;
		font-size: 13.5px;
		color: var(--red);
	}
</style>
