<script lang="ts">
	import { keepFocus } from './reply.svelte';
	import type { Command } from './types';

	const { commands, onpick }: { commands: Command[]; onpick: (name: string) => void } = $props();
</script>

<div class="slash" role="listbox" aria-label="Commands" data-slash>
	{#each commands as command (command.source + command.name)}
		<button
			type="button"
			role="option"
			aria-selected="false"
			{@attach keepFocus}
			onclick={() => onpick(command.name)}
		>
			<b class="mono">/{command.name}</b>
			<span>{command.description}</span>
		</button>
	{/each}
</div>

<style>
	.slash {
		flex: none;
		margin: 0 max(8px, env(safe-area-inset-right)) 6px max(8px, env(safe-area-inset-left));
		border: 1px solid var(--border);
		border-radius: 14px;
		background: #1c1c1e;
		max-height: 236px;
		overflow-y: auto;
		overscroll-behavior: contain;
	}

	button {
		display: flex;
		gap: 10px;
		align-items: baseline;
		width: 100%;
		min-height: var(--hit);
		padding: 11px 14px;
		text-align: left;
		border-bottom: 1px solid #2a2a2c;
	}

	button:last-child {
		border-bottom: 0;
	}

	button:active {
		filter: brightness(1.4);
	}

	b {
		flex: none;
		color: var(--accent);
		font-weight: 600;
	}

	span {
		min-width: 0;
		color: var(--muted);
		font-size: 13px;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}
</style>
