<script lang="ts">
	import { hasThumb, ICONS } from './artifacts';
	import type { Artifacts } from './artifacts.svelte';
	import type { ArtifactFile } from './types';

	const {
		file,
		artifacts,
		onopen
	}: { file: ArtifactFile; artifacts: Artifacts; onopen: (file: ArtifactFile) => void } = $props();
</script>

{#if hasThumb(file)}
	<button class="thumb" data-artifact={file.id} onclick={() => onopen(file)}>
		<!-- The frame keeps its size while the image loads, so the chat does not jump. -->
		<span class="frame">
			{#await artifacts.url(file)}
				<span class="skel"></span>
			{:then src}
				<img {src} alt={file.name} draggable="false" />
			{:catch}
				<span class="miss">{ICONS.image}</span>
			{/await}
		</span>
		<span class="cap">{ICONS.image} {file.name}</span>
	</button>
{:else}
	<button class="fchip" data-artifact={file.id} onclick={() => onopen(file)}>
		<span>{ICONS[file.kind]}</span>
		<span class="name">{file.name}</span>
		<span class="go">›</span>
	</button>
{/if}

<style>
	.thumb {
		align-self: flex-start;
		width: min(78%, 300px);
		border: 1px solid var(--border);
		border-radius: 12px;
		overflow: hidden;
		background: var(--surface);
		text-align: left;
	}

	.frame {
		display: block;
		height: 150px;
		background: #101010;
	}

	.frame img,
	.frame .skel,
	.frame .miss {
		display: block;
		width: 100%;
		height: 100%;
	}

	.frame img {
		object-fit: cover;
		object-position: top;
	}

	.frame .skel {
		border-radius: 0;
	}

	.frame .miss {
		display: flex;
		align-items: center;
		justify-content: center;
		font-size: 28px;
		opacity: 0.5;
	}

	.cap {
		display: block;
		padding: 7px 10px;
		font-size: 12px;
		color: var(--muted);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.fchip {
		align-self: flex-start;
		display: flex;
		align-items: center;
		gap: 8px;
		max-width: 100%;
		min-height: var(--hit);
		padding: 8px 12px;
		border-radius: 10px;
		background: var(--surface);
		border: 1px solid var(--border);
		font-size: 13px;
	}

	.name {
		min-width: 0;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.go {
		color: var(--muted);
	}

	.thumb:active,
	.fchip:active {
		background: #202020;
	}
</style>
