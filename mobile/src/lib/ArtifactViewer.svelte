<script lang="ts">
	import { fileSize, framedHtml, ICONS, isViewable, withoutTargets } from './artifacts';
	import { share, type Artifacts } from './artifacts.svelte';
	import { ui } from './gestures.svelte';
	import type { ArtifactFile } from './types';
	import { Zoom } from './zoom.svelte';

	const { file, artifacts }: { file: ArtifactFile; artifacts: Artifacts } = $props();

	const zoom = new Zoom();
	const viewable = $derived(isViewable(file));

	/** Markdown and code as HTML. The renderer loads with the first file that needs it. */
	async function rendered(file: ArtifactFile): Promise<string> {
		const [text, renderer] = await Promise.all([artifacts.text(file), import('./markdown')]);
		return file.kind === 'markdown'
			? renderer.renderMarkdown(text)
			: renderer.renderCode(text, file.name);
	}

	const html = $derived(
		viewable && file.kind !== 'image' && file.kind !== 'html' ? rendered(file) : null
	);

	let sharing = $state(false);

	async function send(): Promise<void> {
		if (sharing) return;
		sharing = true;
		try {
			await share(await artifacts.blob(file), file.name);
		} catch {
			// The file could not be read: the view already says so.
		} finally {
			sharing = false;
		}
	}
</script>

<div
	class="viewer"
	class:anim={!ui.dragging}
	data-viewer={file.id}
	style:transform="translate3d({ui.backX}px, 0, 0)"
>
	<div class="aback">
		<button class="back" aria-label="Back" onclick={artifacts.back}
			>‹ {artifacts.from === 'chat' ? 'Chat' : 'Artifacts'}</button
		>
		<b>{ICONS[file.kind]} {file.name}</b>
		{#if file.kind === 'image' && viewable}
			<button class="chip grow" aria-label="Zoom" aria-pressed={zoom.zoomed} onclick={zoom.toggle}
				>{zoom.zoomed ? '1×' : '2×'}</button
			>
		{/if}
		<button class="chip grow" disabled={!file.exists || sharing} onclick={send}>Share</button>
	</div>

	{#if !file.exists}
		<div class="empty">Missing</div>
	{:else if !viewable}
		<div class="empty">
			<span class="big">{ICONS[file.kind]}</span>
			<span>{fileSize(file.size)}</span>
		</div>
	{:else if file.kind === 'image'}
		<div class="stage" data-nopage={zoom.holds ? '' : undefined} {@attach zoom.attach}>
			{#await artifacts.url(file)}
				<span class="skel"></span>
			{:then src}
				<img
					{src}
					alt={file.name}
					draggable="false"
					class:anim={!zoom.moving}
					style:transform="translate3d({zoom.x}px, {zoom.y}px, 0) scale({zoom.scale})"
				/>
			{:catch}
				<div class="empty">Not loaded</div>
			{/await}
		</div>
	{:else if file.kind === 'html'}
		{#await artifacts.text(file)}
			<div class="pad"><span class="skel" style:height="120px"></span></div>
		{:then text}
			<div class="framed">
				<!--
					The page is untrusted. An empty `sandbox` runs no script and gives the
					frame no origin, so it cannot read the pairing token or call the API.
				-->
				<iframe
					title={file.name}
					sandbox=""
					referrerpolicy="no-referrer"
					srcdoc={framedHtml(withoutTargets(text))}
				></iframe>
				<!-- A frame keeps the touches on it: the edges stay ours, for the swipes. -->
				<span class="edge left"></span>
				<span class="edge right"></span>
			</div>
		{:catch}
			<div class="empty">Not loaded</div>
		{/await}
	{:else}
		<div class="scroll">
			{#await html}
				<div class="pad">
					{#each [70, 92, 84, 60] as width (width)}
						<span class="skel" style:width="{width}%" style:height="14px"></span>
					{/each}
				</div>
			{:then body}
				{#if file.kind === 'markdown'}
					<!-- eslint-disable-next-line svelte/no-at-html-tags -- markdown.ts renders with raw HTML off -->
					<div class="md">{@html body}</div>
				{:else}
					<!-- eslint-disable-next-line svelte/no-at-html-tags -- markdown.ts escapes the text -->
					<pre class="code mono hljs" data-hscroll><code>{@html body}</code></pre>
				{/if}
			{:catch}
				<div class="empty">Not loaded</div>
			{/await}
		</div>
	{/if}
</div>

<style>
	.viewer {
		position: absolute;
		inset: 0;
		z-index: 3;
		display: flex;
		flex-direction: column;
		background: var(--bg);
		animation: in 0.2s ease-out;
		will-change: transform;
	}

	.viewer.anim {
		transition: transform 0.26s var(--ease);
	}

	@keyframes in {
		from {
			transform: translateX(40%);
			opacity: 0.3;
		}
	}

	.aback {
		flex: none;
		display: flex;
		align-items: center;
		gap: 10px;
		min-height: var(--hit);
		padding: 0 12px 0 4px;
		background: var(--bar);
		border-bottom: 1px solid var(--border);
	}

	.back {
		flex: none;
		min-height: var(--hit);
		padding: 0 8px;
		color: var(--accent);
		font-size: 15px;
	}

	.aback b {
		flex: 1;
		min-width: 0;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
		font-size: 14px;
	}

	.empty {
		flex: 1;
		display: flex;
		flex-direction: column;
		gap: 8px;
		align-items: center;
		justify-content: center;
		color: var(--muted);
	}

	.big {
		font-size: 44px;
	}

	.pad {
		display: flex;
		flex-direction: column;
		gap: 10px;
		padding: 18px;
	}

	.stage {
		flex: 1;
		min-height: 0;
		display: flex;
		align-items: center;
		justify-content: center;
		overflow: clip;
		/* Two fingers scale the image; the browser must not take them for a scroll. */
		touch-action: none !important;
	}

	.stage img {
		max-width: 100%;
		max-height: 100%;
		object-fit: contain;
		touch-action: none !important;
		-webkit-user-select: none;
		user-select: none;
	}

	.stage img.anim {
		transition: transform 0.2s var(--ease);
	}

	.stage .skel {
		width: 70%;
		height: 40%;
	}

	.framed {
		position: relative;
		flex: 1;
		min-height: 0;
		background: #fff;
	}

	iframe {
		display: block;
		width: 100%;
		height: 100%;
		border: 0;
		background: #fff;
	}

	.edge {
		position: absolute;
		top: 0;
		bottom: 0;
		width: 28px;
	}

	.edge.left {
		left: 0;
	}

	.edge.right {
		right: 0;
	}

	.code {
		margin: 0;
		padding: 12px 14px calc(16px + env(safe-area-inset-bottom));
		font-size: 12px;
		line-height: 1.45;
		white-space: pre;
		/* Moved by the gesture controller, so a long line scrolls before a tab changes. */
		overflow-x: hidden;
		min-height: 100%;
	}

	.code code {
		font-family: inherit;
	}

	.md {
		padding: 14px 18px calc(18px + env(safe-area-inset-bottom));
		overflow-wrap: anywhere;
	}

	.md :global(h1),
	.md :global(h2),
	.md :global(h3) {
		margin: 18px 0 8px;
		line-height: 1.25;
	}

	.md :global(h1) {
		font-size: 22px;
	}

	.md :global(h2) {
		font-size: 18px;
	}

	.md :global(h3) {
		font-size: 16px;
	}

	.md :global(:first-child) {
		margin-top: 0;
	}

	.md :global(p),
	.md :global(ul),
	.md :global(ol) {
		margin: 0 0 12px;
	}

	.md :global(li) {
		margin: 6px 0;
	}

	.md :global(a) {
		color: var(--accent);
		-webkit-user-select: auto;
		user-select: auto;
	}

	.md :global(code) {
		font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
		font-size: 13px;
		background: var(--surface);
		padding: 1px 5px;
		border-radius: 5px;
	}

	.md :global(pre) {
		margin: 0 0 12px;
		padding: 10px 12px;
		border-radius: 10px;
		background: var(--surface);
		font-size: 12px;
		line-height: 1.45;
		white-space: pre;
		overflow-x: hidden;
	}

	.md :global(pre code) {
		background: none;
		padding: 0;
		font-size: inherit;
	}

	.md :global(blockquote) {
		margin: 0 0 12px;
		padding-left: 12px;
		border-left: 3px solid var(--border);
		color: #cfcfcf;
	}

	.md :global(table) {
		border-collapse: collapse;
		margin-bottom: 12px;
		font-size: 13.5px;
	}

	.md :global(th),
	.md :global(td) {
		border: 1px solid var(--border);
		padding: 4px 8px;
		text-align: left;
	}

	.md :global(hr) {
		border: 0;
		border-top: 1px solid var(--border);
		margin: 16px 0;
	}

	@media (prefers-reduced-motion: reduce) {
		.viewer {
			animation: none;
		}
	}
</style>
