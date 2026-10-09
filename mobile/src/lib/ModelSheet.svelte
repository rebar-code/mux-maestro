<script lang="ts">
	import Icon from './Icon.svelte';
	import type { ModelPicker } from './model.svelte';

	const { picker }: { picker: ModelPicker } = $props();

	const open = $derived(picker.stage !== 'closed');
	const title = $derived(
		picker.stage === 'efforts' && picker.picked ? `${picker.picked.label} effort` : 'Model'
	);

	function onkeydown(event: KeyboardEvent): void {
		if (open && event.key === 'Escape') picker.close();
	}
</script>

<svelte:window {onkeydown} />

{#if open}
	<button class="scrim" aria-label="Close" onclick={picker.close}></button>
	<div
		class="sheet"
		role="dialog"
		aria-modal="true"
		aria-label={title}
		aria-busy={picker.busy}
		data-model-sheet={picker.stage}
		{@attach () => picker.close}
	>
		<div class="title">{title}</div>
		<div class="list">
			{#if picker.stage === 'models'}
				{#each picker.models as model (model.n)}
					<button
						class="item"
						disabled={picker.busy}
						aria-current={model.current}
						data-model={model.label}
						onclick={() => picker.pick(model)}
					>
						<span>{model.label}</span>
						{#if model.current}<Icon name="check" size={18} />{/if}
					</button>
				{/each}
			{:else if picker.stage === 'efforts'}
				{#each picker.efforts as effort (effort.label)}
					<button
						class="item"
						disabled={picker.busy}
						aria-current={effort.current}
						data-effort={effort.label}
						onclick={() => picker.apply(effort.label)}
					>
						<span>{effort.label}</span>
						{#if effort.current}<Icon name="check" size={18} />{/if}
					</button>
				{/each}
			{:else if !picker.error}
				<div class="item"><span class="skel" style:width="60%" style:height="14px"></span></div>
				<div class="item"><span class="skel" style:width="45%" style:height="14px"></span></div>
			{/if}
		</div>
		{#if picker.error}<div class="error" role="alert">{picker.error}</div>{/if}
		{#if picker.stage === 'efforts'}
			<button class="item" disabled={picker.busy} onclick={picker.back}>Back</button>
		{/if}
		<button class="item" onclick={picker.close}>Cancel</button>
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
		bottom: calc(8px + var(--safe-bottom, env(safe-area-inset-bottom)));
		z-index: 51;
		display: flex;
		flex-direction: column;
		max-height: 70%;
		background: #1c1c1e;
		border-radius: 14px;
		overflow: hidden;
	}

	.title {
		padding: 14px 16px 10px;
		font-size: 12px;
		color: var(--muted);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.list {
		overflow-y: auto;
		overscroll-behavior: contain;
		min-height: 0;
	}

	.item {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
		flex: none;
		width: 100%;
		min-height: 50px;
		padding: 0 16px;
		text-align: left;
		border-top: 1px solid #2c2c2e;
		font-size: 16px;
	}

	.item:not(:disabled):active {
		background: #2c2c2e;
	}

	.item:disabled {
		opacity: 0.5;
	}

	.item[aria-current='true'] {
		color: var(--accent);
	}

	.error {
		padding: 10px 16px 12px;
		border-top: 1px solid #2c2c2e;
		font-size: 13.5px;
		color: var(--red);
	}
</style>
