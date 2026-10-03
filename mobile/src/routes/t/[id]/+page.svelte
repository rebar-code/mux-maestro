<script lang="ts">
	import ThreadView from '$lib/ThreadView.svelte';

	const { data } = $props();
</script>

{#key data.id}
	<ThreadView id={data.id} />
{/key}
