<script lang="ts">
	import { keepFocus } from './reply.svelte';

	const {
		busy,
		disabled,
		onpick
	}: {
		/** An upload is in flight. */
		busy: boolean;
		disabled: boolean;
		onpick: (file: File) => void;
	} = $props();

	function picked(event: Event & { currentTarget: HTMLInputElement }): void {
		const picker = event.currentTarget;
		const file = picker.files?.[0];
		// Emptied, so the same file can be picked again.
		picker.value = '';
		if (file) onpick(file);
	}

	/** The file picker sits right before the button. */
	function open(event: MouseEvent & { currentTarget: HTMLButtonElement }): void {
		(event.currentTarget.previousElementSibling as HTMLInputElement).click();
	}
</script>

<!-- No `capture`: iOS then offers the photo library, the camera and files. -->
<input type="file" hidden tabindex="-1" onchange={picked} data-attach-input />
<button
	class="rnd"
	class:busy
	type="button"
	aria-label="Attach"
	aria-busy={busy}
	disabled={disabled || busy}
	{@attach keepFocus}
	onclick={open}
>
	{#if busy}<i class="spin"></i>{:else}＋{/if}
</button>

<style>
	/* The look is a 40pt circle; the touch area is 44pt. */
	.rnd {
		position: relative;
		flex: none;
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 40px;
		height: 40px;
		border-radius: 50%;
		background: var(--surface);
		border: 1px solid var(--border);
		font-size: 18px;
		line-height: 1;
	}

	.rnd::after {
		content: '';
		position: absolute;
		inset: -3px;
	}

	/* Still readable as "working", not as "off". */
	.rnd.busy:disabled {
		opacity: 1;
	}

	.spin {
		width: 16px;
		height: 16px;
		border-radius: 50%;
		border: 2px solid #555;
		border-top-color: var(--text);
		animation: spin 0.8s linear infinite;
	}

	@keyframes spin {
		to {
			transform: rotate(360deg);
		}
	}
</style>
