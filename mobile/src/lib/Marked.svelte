<script lang="ts">
	import { segments, type Hit } from './find';

	const { text, hits, current }: { text: string; hits: Hit[]; current: number } = $props();

	const parts = $derived(segments(text, hits));
</script>

{#each parts as part, n (n)}{#if part.hit === null}{part.text}{:else}<mark
			class:cur={part.hit === current}
			data-find-current={part.hit === current ? '' : undefined}>{part.text}</mark
		>{/if}{/each}

<style>
	mark {
		background: #6b5310;
		color: inherit;
		border-radius: 2px;
	}

	mark.cur {
		background: var(--amber);
		color: #000;
	}
</style>
