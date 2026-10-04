<script lang="ts">
	import type { Attachment } from 'svelte/attachments';
	import type { FormEventHandler } from 'svelte/elements';
	import { boxCap, enterSends, hasHardwareKeyboard } from './compose';
	import { keyboardInset } from './pager';

	/**
	 * The text box of every composer: it wraps, and grows with its text up to a
	 * cap, then scrolls inside. The growth is the browser's own: a hidden copy
	 * of the text in the same grid cell gives the cell its height.
	 */
	// `value` is bound, so the whole pattern is a `let`.
	/* eslint-disable prefer-const */
	let {
		value = $bindable(),
		label,
		disabled = false,
		onsend,
		oninput,
		onbeforeinput,
		onpaste,
		onfocus,
		onblur,
		box
	}: {
		value: string;
		/** The placeholder, and the box's name. */
		label: string;
		disabled?: boolean;
		/** Enter on real keys. A touch keyboard's Return is a new line. */
		onsend?: () => void;
		oninput?: FormEventHandler<HTMLTextAreaElement>;
		onbeforeinput?: (event: InputEvent) => void;
		onpaste?: (event: ClipboardEvent) => void;
		onfocus?: () => void;
		onblur?: () => void;
		/** Attachment for the text box, for a caller that types into it or moves the focus. */
		box?: Attachment<HTMLTextAreaElement>;
	} = $props();
	/* eslint-enable prefer-const */

	function keydown(event: KeyboardEvent & { currentTarget: HTMLTextAreaElement }): void {
		const visible = window.visualViewport?.height ?? window.innerHeight;
		const sends = enterSends({
			key: event.key,
			shiftKey: event.shiftKey,
			metaKey: event.metaKey,
			ctrlKey: event.ctrlKey,
			isComposing: event.isComposing,
			keyCode: event.keyCode,
			finePointer: hasHardwareKeyboard({
				fine: matchMedia('(pointer: fine)').matches,
				hover: matchMedia('(hover: hover)').matches
			}),
			focused: document.activeElement === event.currentTarget,
			keyboardUp: keyboardInset(document.documentElement.clientHeight, visible) > 0
		});
		if (!sends) return;
		event.preventDefault();
		onsend?.();
	}

	/** Attachment: the tallest the box gets, from what of the screen is visible now. */
	function cap(node: HTMLElement): () => void {
		const area = node.querySelector('textarea');
		// Prose: the keyboard corrects it. (Not in the element's typed attributes.)
		area?.setAttribute('autocorrect', 'on');
		const fit = (): void => {
			if (!area) return;
			const style = getComputedStyle(area);
			const chrome = parseFloat(style.paddingTop) + parseFloat(style.paddingBottom);
			const visible = window.visualViewport?.height ?? window.innerHeight;
			node.style.setProperty('--cap', `${boxCap(parseFloat(style.lineHeight), chrome, visible)}px`);
		};
		fit();
		// Again once the box has its styles and its width.
		const sized = new ResizeObserver(fit);
		sized.observe(node);
		window.visualViewport?.addEventListener('resize', fit);
		window.addEventListener('resize', fit);
		return () => {
			sized.disconnect();
			window.visualViewport?.removeEventListener('resize', fit);
			window.removeEventListener('resize', fit);
		};
	}
</script>

<div class="field" class:off={disabled} data-value={value} data-growing {@attach cap}>
	<textarea
		rows="1"
		bind:value
		{@attach box}
		placeholder={label}
		aria-label={label}
		enterkeyhint="enter"
		autocomplete="off"
		autocapitalize="sentences"
		spellcheck="true"
		{disabled}
		onkeydown={keydown}
		{oninput}
		{onbeforeinput}
		{onpaste}
		{onfocus}
		{onblur}></textarea>
</div>

<style>
	.field {
		flex: 1;
		min-width: 0;
		display: grid;
		/* One row that gives way: past the cap the row stops and the box scrolls inside. */
		grid-template-rows: minmax(0, 1fr);
		/* One line is a touch target; more lines grow it, up to the cap. */
		min-height: var(--hit);
		max-height: var(--cap, 198px);
		border-radius: 22px;
		/* Drawn inside, so the text box itself is the whole touch target. */
		box-shadow: inset 0 0 0 1px var(--border);
		background: var(--surface);
		overflow: hidden;
	}

	.field:focus-within {
		box-shadow: inset 0 0 0 1px var(--accent);
	}

	/* The text again, unseen: it is what makes the cell as tall as the text. */
	.field::after {
		content: attr(data-value) ' ';
		visibility: hidden;
		overflow: hidden;
	}

	.field::after,
	textarea {
		grid-area: 1 / 1;
		min-width: 0;
		min-height: 0;
		margin: 0;
		padding: 11px 14px;
		border: 0;
		/* 16px: a smaller box makes iOS zoom the page on focus. */
		font: inherit;
		font-size: 16px;
		line-height: 22px;
		white-space: pre-wrap;
		overflow-wrap: anywhere;
	}

	textarea {
		display: block;
		width: 100%;
		/* As tall as the cell: the unseen copy sets that, not the box's own rows. */
		height: auto;
		align-self: stretch;
		resize: none;
		background: none;
		color: var(--text);
		outline: none;
		overflow-y: auto;
		overscroll-behavior: contain;
		/*
		 * Text that scrolls out fades at a straight edge, inside the rounded
		 * ends, so no line is cut by a corner. Text that is not scrolled starts
		 * below the fade and is whole.
		 */
		-webkit-mask-image: linear-gradient(
			transparent 2px,
			#000 10px,
			#000 calc(100% - 10px),
			transparent calc(100% - 2px)
		);
		mask-image: linear-gradient(
			transparent 2px,
			#000 10px,
			#000 calc(100% - 10px),
			transparent calc(100% - 2px)
		);
		-webkit-user-select: text;
		user-select: text;
	}

	/* Off, not broken: the label stays readable. */
	textarea:disabled {
		opacity: 1;
		color: var(--muted);
		-webkit-text-fill-color: var(--muted);
	}

	textarea:disabled::placeholder {
		color: var(--muted);
		opacity: 1;
	}
</style>
