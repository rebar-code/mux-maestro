<script lang="ts">
	import type { Servers } from './servers.svelte';

	const { servers }: { servers: Servers } = $props();

	function onkeydown(event: KeyboardEvent): void {
		if (servers.asking !== null && event.key === 'Escape') servers.cancel();
	}
</script>

<svelte:window {onkeydown} />

{#if servers.asking !== null}
	<button class="scrim" aria-label="Cancel" onclick={servers.cancel}></button>
	<div class="sheet" role="alertdialog" aria-modal="true" aria-labelledby="serve-title">
		<b id="serve-title">Open port {servers.asking} on your tailnet?</b>
		<p>
			Every device on your tailnet can then open this server. It does not need the pairing code. The
			port closes when you close it here, when the server stops, or after 30 minutes.
		</p>
		<button class="act yes" onclick={servers.confirm}>Open</button>
		<button class="act" onclick={servers.cancel}>Cancel</button>
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
	}

	.sheet {
		position: absolute;
		left: max(8px, env(safe-area-inset-left));
		right: max(8px, env(safe-area-inset-right));
		bottom: calc(8px + env(safe-area-inset-bottom));
		z-index: 51;
		display: flex;
		flex-direction: column;
		gap: 8px;
		padding: 16px;
		background: #1c1c1e;
		border-radius: 14px;
	}

	.sheet p {
		margin: 0 0 6px;
		font-size: 14px;
		color: #cfcfcf;
	}

	.act {
		min-height: var(--hit);
		border-radius: 10px;
		background: var(--surface);
		border: 1px solid var(--border);
		font-weight: 600;
	}

	.act.yes {
		background: var(--accent);
		border-color: var(--accent);
		color: #fff;
	}
</style>
