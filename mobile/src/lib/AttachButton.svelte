<script lang="ts">
	import Icon from './Icon.svelte';
	import { keepFocus } from './reply.svelte';

	const {
		off = false,
		disabled = false,
		slim = false,
		onpick,
		onoff
	}: {
		/** Uploads are switched off on the Mac: the button is dimmed and a tap says so. */
		off?: boolean;
		/** The whole reply box is off: the button does nothing. */
		disabled?: boolean;
		/** It sits in the key bar: the bar's size, not the text box's. */
		slim?: boolean;
		/** The files picked, in pick order. */
		onpick?: (files: File[]) => void;
		/** A tap while `off`. */
		onoff?: () => void;
	} = $props();

	function picked(event: Event & { currentTarget: HTMLInputElement }): void {
		const picker = event.currentTarget;
		const files = [...(picker.files ?? [])];
		// Emptied, so the same file can be picked again.
		picker.value = '';
		if (files.length) onpick?.(files);
	}

	/** The file picker sits right before the button. */
	function open(event: MouseEvent & { currentTarget: HTMLButtonElement }): void {
		if (off) return onoff?.();
		(event.currentTarget.previousElementSibling as HTMLInputElement).click();
	}
</script>

<!-- No `accept`, no `capture`: iOS then offers the photo library, the camera and files. -->
<input type="file" multiple hidden tabindex="-1" onchange={picked} data-attach-input />
<button
	class="rnd"
	class:slim
	class:off={off || disabled}
	type="button"
	aria-label="Attach"
	aria-disabled={off || disabled ? 'true' : undefined}
	{disabled}
	{@attach keepFocus}
	onclick={open}><Icon name="fileUp" size={slim ? 17 : 19} /></button
>

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
		color: #cfcfcf;
	}

	.rnd::after {
		content: '';
		position: absolute;
		inset: -3px;
	}

	/* In the key bar: the look is the strip's; the touch area is a full 44pt. */
	.rnd.slim {
		z-index: 1;
		width: 34px;
		height: 23px;
		border: 0;
		border-radius: 8px;
		background: none;
	}

	.rnd.slim::after {
		inset: auto;
		left: 50%;
		top: 50%;
		width: var(--hit);
		height: var(--hit);
		transform: translate(-50%, -50%);
	}

	.rnd.slim:active {
		background: #0c0c0c;
	}

	/* Switched off: dimmed, and still there to say why. */
	.rnd.off {
		opacity: 0.35;
	}
</style>
