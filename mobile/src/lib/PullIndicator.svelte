<script lang="ts">
	import { ui } from './gestures.svelte';

	const { key }: { key: string } = $props();

	const mine = $derived(ui.pullKey === key);
	const height = $derived(mine ? ui.pull : 0);
	const busy = $derived(ui.refreshing === key);
</script>

<div class="pull" class:anim={!(mine && ui.pulling)} style:height="{height}px" aria-hidden="true">
	<span class:busy style:transform="rotate({height * 4}deg)">↻</span>
</div>

<style>
	.pull {
		display: flex;
		align-items: center;
		justify-content: center;
		overflow: hidden;
		color: var(--muted);
		font-size: 18px;
	}

	.pull.anim {
		transition: height 0.2s var(--ease);
	}

	.busy {
		animation: spin 0.8s linear infinite;
	}

	@keyframes spin {
		to {
			transform: rotate(360deg);
		}
	}
</style>
