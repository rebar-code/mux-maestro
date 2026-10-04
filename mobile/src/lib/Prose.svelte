<script lang="ts">
	import { hasThumb, resolveArtifact } from './artifacts';
	import type { Hit } from './find';
	import { proseTaps, type ProseLinks } from './prose';
	import { renderer } from './renderer.svelte';

	const {
		text,
		hits,
		current = 0,
		links,
		live = false
	}: {
		text: string;
		hits?: Hit[];
		current?: number;
		links?: ProseLinks;
		/** The text is still arriving: it is not kept once it has changed. */
		live?: boolean;
	} = $props();

	// One string for each top-level block. A message that grows changes its
	// last block only: the blocks before it keep their elements. Null until the
	// renderer has loaded.
	const blocks = $derived.by(() => {
		const api = renderer.api;
		if (!api) return null;
		if (live) return api.liveBlocks(text);
		return hits ? api.markedBlocks(text, hits, current) : api.chatBlocks(text);
	});

	/**
	 * After the blocks are drawn: say which paths are files of the thread, and
	 * put the picture in an image that is one. The picture comes from the
	 * thread's own file read, never from the address in the message.
	 */
	function known(node: HTMLElement): void {
		if (!blocks?.length) return;
		const files = links?.files ?? [];
		for (const el of node.querySelectorAll<HTMLElement>('[data-local]')) {
			el.toggleAttribute('data-known', Boolean(links?.local));
		}
		for (const el of node.querySelectorAll<HTMLElement>('[data-file], [data-img]')) {
			const file = resolveArtifact(el.dataset.file ?? el.dataset.img ?? '', files);
			el.toggleAttribute('data-known', file !== null);
			if (!file || !links || el.dataset.img === undefined || !hasThumb(file)) continue;
			if (el.querySelector('img')) continue;
			links.url(file).then(
				(src) => {
					if (!el.isConnected || el.querySelector('img')) return;
					const img = document.createElement('img');
					img.src = src;
					img.alt = '';
					img.draggable = false;
					el.prepend(img);
				},
				() => {
					// Not read: the chip stays.
				}
			);
		}
	}
</script>

<div class="prose" {@attach proseTaps(() => links)} {@attach known}>
	{#if blocks}
		{#each blocks as html, index (index)}
			<!-- eslint-disable-next-line svelte/no-at-html-tags -- markdown.ts renders with raw HTML off and escapes the text -->
			{@html html}
		{/each}
	{:else}
		<p class="plain">{text}</p>
	{/if}
</div>
