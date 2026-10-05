<script lang="ts">
	import { resolve } from '$app/paths';
	import RequestList from '$lib/RequestList.svelte';
</script>

<svelte:head><title>Requests</title></svelte:head>

<header class="tbar">
	<a class="tb" href={resolve('/')} aria-label="Back">‹</a>
	<div class="title"><b>Requests</b></div>
</header>

<RequestList />

<style>
	.tbar a.tb {
		font-size: 26px;
		line-height: 1;
		padding-bottom: 3px;
	}

	.title b {
		font-size: 16px;
	}
</style>
