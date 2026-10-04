<script lang="ts">
	import { hasThumb, resolveArtifact } from './artifacts';
	import type { Hit } from './find';
	import { chatBlocks, markedBlocks } from './markdown';
	import { proseTaps, type ProseLinks } from './prose';

	const {
		text,
		hits,
		current = 0,
		links
	}: { text: string; hits?: Hit[]; current?: number; links?: ProseLinks } = $props();

	// One string for each top-level block. A message that grows changes its
	// last block only: the blocks before it keep their elements.
	const blocks = $derived(hits ? markedBlocks(text, hits, current) : chatBlocks(text));

	/**
	 * After the blocks are drawn: say which paths are files of the thread, and
	 * put the picture in an image that is one. The picture comes from the
	 * thread's own file read, never from the address in the message.
	 */
	function known(node: HTMLElement): void {
		if (!blocks.length) return;
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
	{#each blocks as html, index (index)}
		<!-- eslint-disable-next-line svelte/no-at-html-tags -- markdown.ts renders with raw HTML off and escapes the text -->
		{@html html}
	{/each}
</div>
