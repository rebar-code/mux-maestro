<script lang="ts">
	import { live } from './live.svelte';

	let value = $state('');
	let invalid = $state(false);
	let busy = $state(false);

	async function submit(event: SubmitEvent): Promise<void> {
		event.preventDefault();
		if (busy) return;
		busy = true;
		invalid = !(await live.pair(value));
		busy = false;
	}
</script>

<form class="pair" onsubmit={submit} novalidate>
	<h1>Not paired</h1>
	<input
		bind:value
		oninput={() => (invalid = false)}
		placeholder="Pairing link"
		aria-label="Pairing link"
		aria-invalid={invalid}
		type="text"
		inputmode="url"
		enterkeyhint="go"
		autocapitalize="off"
		autocomplete="off"
		autocorrect="off"
		spellcheck="false"
	/>
	<button type="submit" disabled={busy}>Pair</button>
</form>

<style>
	.pair {
		display: flex;
		flex-direction: column;
		gap: 12px;
		height: 100%;
		/* High on the screen, so the keyboard does not cover it. */
		padding: calc(18vh + env(safe-area-inset-top)) max(24px, env(safe-area-inset-right))
			env(safe-area-inset-bottom) max(24px, env(safe-area-inset-left));
	}

	h1 {
		margin: 0 0 8px;
		font-size: 22px;
		font-weight: 700;
		text-align: center;
	}

	input {
		height: 48px;
		padding: 0 14px;
		border-radius: 12px;
		border: 1px solid var(--border);
		background: var(--surface);
		color: var(--text);
		/* 16px: below that, iOS zooms the page when the field takes focus. */
		font: inherit;
		font-size: 16px;
		outline: none;
		-webkit-appearance: none;
		appearance: none;
	}

	input:focus {
		border-color: var(--accent);
	}

	input[aria-invalid='true'] {
		border-color: var(--red);
	}

	input::placeholder {
		color: var(--muted);
	}

	button {
		height: 48px;
		border-radius: 12px;
		background: var(--accent);
		color: #fff;
		font-size: 16px;
		font-weight: 600;
	}

	button:not(:disabled):active {
		filter: brightness(1.2);
	}
</style>
