<script lang="ts">
	/** The prompt Claude Code suggests in the pane. A tap puts it in the text box. */
	const { text, onpick }: { text: string; onpick: () => void } = $props();
</script>

<button type="button" class="suggestion" aria-label="Suggestion" data-suggestion onclick={onpick}>
	{text}
</button>

<style>
	.suggestion {
		flex: none;
		display: block;
		min-height: var(--hit);
		margin: 0 max(10px, env(safe-area-inset-right)) 6px max(10px, env(safe-area-inset-left));
		padding: 0 12px;
		border: 1px dashed var(--border);
		border-radius: 12px;
		background: none;
		color: var(--muted);
		font: inherit;
		text-align: left;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.suggestion:active {
		filter: brightness(1.3);
	}
</style>
