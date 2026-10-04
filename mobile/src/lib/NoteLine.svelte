<script lang="ts">
	/** One line for what the last key or answer came to, where no composer says it. */
	const { note }: { note: { text: string; bad: boolean } } = $props();
</script>

<div class="knote" class:bad={note.bad} role="alert" data-note>{note.text}</div>

<style>
	.knote {
		flex: none;
		padding: 0 max(18px, env(safe-area-inset-right)) 6px max(18px, env(safe-area-inset-left));
		font-size: 12.5px;
		color: var(--muted);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.knote.bad {
		color: var(--red);
	}
</style>
