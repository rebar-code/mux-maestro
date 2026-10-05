<script lang="ts">
	import { maestro } from './maestro.svelte';

	/**
	 * The way back to the Maestro, above a session's reply box. Shown on a page
	 * a jump opened, until it is used or dismissed.
	 */
</script>

<div class="back" data-maestro-back>
	<button class="go" onclick={maestro.show}>✦ Back to Maestro</button>
	<button class="tb" aria-label="Dismiss" onclick={maestro.seen}>✕</button>
</div>

<style>
	.back {
		display: flex;
		align-items: center;
		gap: 4px;
		margin: 8px 10px 0;
		padding-left: 4px;
		border-radius: 12px;
		background: #2a2440;
		border: 1px solid var(--purple);
	}

	.go {
		flex: 1;
		min-height: var(--hit);
		padding: 0 10px;
		text-align: left;
		color: #e6dcff;
		font-size: 14px;
	}

	.tb {
		color: #b9a8e6;
	}
</style>
