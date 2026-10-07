<script lang="ts">
	import { FILTERS, type Filter } from './group';
	import Icon from './Icon.svelte';
	import { live } from './live.svelte';

	/**
	 * The sidebar's filter. A tap on the left part turns Sleepy on, or any mode
	 * off; the arrow lists the modes. `onchange`: the list has a new length.
	 */
	const { onchange }: { onchange: () => void } = $props();

	let open = $state(false);
	const on = $derived(live.filter !== 'off');
	const label = $derived(FILTERS.find((option) => option.key === live.filter)?.label);

	const toggle = (): void => {
		live.toggleFilter();
		onchange();
	};

	const pick = (filter: Filter): void => {
		open = false;
		if (filter === live.filter) return;
		live.setFilter(filter);
		onchange();
	};
</script>

<div class="filt" class:on data-filter={live.filter}>
	<button class="tb main" aria-label="Filter" aria-pressed={on} onclick={toggle}>
		<Icon name="filter" />
		{#if label}<span class="mode">{label}</span>{/if}
	</button>
	<button
		class="tb arrow"
		aria-label="Filter options"
		aria-haspopup="menu"
		aria-expanded={open}
		onclick={() => (open = !open)}><Icon name="chevronDown" size={16} /></button
	>
	{#if open}
		<button class="scrim" aria-label="Close" onclick={() => (open = false)}></button>
		<div class="menu" role="menu">
			{#each FILTERS as option (option.key)}
				<button
					role="menuitemradio"
					aria-checked={live.filter === option.key}
					onclick={() => pick(option.key)}
				>
					<span>{option.label}</span>
					{#if live.filter === option.key}<Icon name="check" size={16} />{/if}
				</button>
			{/each}
		</div>
	{/if}
</div>

<style>
	.filt {
		position: relative;
		flex: none;
		display: flex;
		border: 1px solid #2b2b3d;
		border-radius: 10px;
	}

	.filt.on {
		border-color: var(--accent);
		background: #1b2333;
		color: var(--accent);
	}

	.filt .tb {
		color: inherit;
	}

	.main {
		gap: 6px;
		padding: 0 4px 0 12px;
		border-radius: 10px 0 0 10px;
		font-size: 13px;
		font-weight: 600;
	}

	.arrow {
		border-radius: 0 10px 10px 0;
	}

	/* Over the sidebar: a tap anywhere else closes the menu. */
	.scrim {
		position: fixed;
		inset: 0;
		z-index: 1;
	}

	.menu {
		position: absolute;
		left: 0;
		bottom: calc(100% + 6px);
		z-index: 2;
		min-width: 150px;
		padding: 4px;
		border: 1px solid #2b2b3d;
		border-radius: 10px;
		background: var(--surface);
		box-shadow: 0 6px 24px rgba(0, 0, 0, 0.5);
		color: #cfcfcf;
	}

	.menu button {
		display: flex;
		align-items: center;
		justify-content: space-between;
		width: 100%;
		min-height: var(--hit);
		padding: 0 12px;
		border-radius: 7px;
		font-size: 15px;
		text-align: left;
	}

	.menu button[aria-checked='true'] {
		color: var(--accent);
	}

	.menu button:active {
		background: #232323;
	}
</style>
