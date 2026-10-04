<script lang="ts">
	import { tileLabel, type Attached } from './attach';
	import type { Attachments } from './attach.svelte';
	import { keepFocus } from './reply.svelte';

	/** The files picked for a reply, one tile each. The row scrolls sideways. */
	const { files }: { files: Attachments } = $props();
</script>

{#snippet face(item: Attached, url: string | undefined, again: boolean)}
	{#if url}
		<img src={url} alt="" />
	{:else}
		<span class="glyph" aria-hidden="true">📄</span>
	{/if}
	<b>{item.name}</b>
	<span class="line">
		<span class="st" data-tile-label>{tileLabel(item)}</span>
		{#if again}<span class="re" aria-hidden="true">↻</span>{/if}
	</span>
{/snippet}

<div class="tiles" data-tiles data-hscroll role="list" aria-label="Attachments">
	{#each files.items as item (item.key)}
		{@const url = files.urls[item.key]}
		{@const again = item.state === 'failed' && item.retry}
		<div class="tile {item.state}" role="listitem" data-tile={item.name} data-state={item.state}>
			<!-- A failed file that can go again: the tile itself is the retry. -->
			{#if again}
				<button
					class="main"
					type="button"
					aria-label="Retry {item.name}"
					{@attach keepFocus}
					onclick={() => files.retry(item.key)}
				>
					{@render face(item, url, true)}
				</button>
			{:else}
				<div class="main">{@render face(item, url, false)}</div>
			{/if}
			{#if item.state === 'uploading'}
				<span
					class="bar"
					role="progressbar"
					aria-label="Uploading {item.name}"
					aria-valuemin="0"
					aria-valuemax="100"
					aria-valuenow={Math.round(item.progress * 100)}
					><i style:width="{item.progress * 100}%"></i></span
				>
			{/if}
			<button
				class="rm"
				type="button"
				aria-label="Remove {item.name}"
				{@attach keepFocus}
				onclick={() => files.remove(item.key)}>✕</button
			>
		</div>
	{/each}
</div>

<style>
	.tiles {
		flex: 0 0 100%;
		min-width: 0;
		display: flex;
		gap: 8px;
		/* One height in every state, so the text box below never moves. */
		height: 78px;
		/* Moved by the gesture controller, like the key bar. */
		overflow: hidden;
	}

	/* Three fit side by side on a phone; a fourth scrolls in. */
	.tile {
		position: relative;
		flex: none;
		width: 112px;
		height: 78px;
		border-radius: 12px;
		background: var(--surface);
		border: 1px solid var(--border);
		overflow: hidden;
	}

	.tile.failed {
		border-color: #5a2320;
		background: #1f1110;
	}

	.main {
		display: flex;
		flex-direction: column;
		align-items: flex-start;
		width: 100%;
		height: 100%;
		padding: 5px 7px 0;
		text-align: left;
	}

	button.main:active {
		filter: brightness(1.4);
	}

	img,
	.glyph {
		flex: none;
		width: 36px;
		height: 36px;
		margin-bottom: 3px;
		border-radius: 7px;
	}

	img {
		object-fit: cover;
		background: #0a0a0a;
	}

	.glyph {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		background: #0c0c0c;
		font-size: 19px;
	}

	b,
	.st {
		max-width: 100%;
		line-height: 1.25;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.line {
		display: flex;
		gap: 4px;
		max-width: 100%;
		line-height: 1.25;
	}

	/* The tile can be tapped to send the file again. */
	.re {
		flex: none;
		font-size: 11.5px;
		color: var(--text);
	}

	b {
		font-size: 11.5px;
		font-weight: 600;
	}

	.st {
		font-size: 11.5px;
		color: var(--muted);
	}

	.failed .st {
		color: var(--red);
	}

	.done .st {
		color: var(--green);
	}

	/* Along the bottom edge, so it takes no room of its own. */
	.bar {
		position: absolute;
		left: 0;
		right: 0;
		bottom: 0;
		height: 3px;
		background: #2a2a2a;
	}

	.bar i {
		display: block;
		height: 100%;
		background: var(--accent);
	}

	/* A 44pt touch area in the tile's top corner. */
	.rm {
		position: absolute;
		top: 0;
		right: 0;
		width: var(--hit);
		height: var(--hit);
		border-radius: 10px;
		font-size: 14px;
		color: #cfcfcf;
	}

	.rm:active {
		background: #2a2a2a;
	}
</style>
