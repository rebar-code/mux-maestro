<script lang="ts">
	import { push } from './push.svelte';
</script>

<div class="nrow" data-push={push.status}>
	<div class="text">
		<span class="label">Notifications</span>
		{#if push.status === 'install'}
			<span class="hint">Add this app to the Home Screen first</span>
		{/if}
	</div>
	{#if push.failed}
		<span class="state" role="status">Failed</span>
	{/if}
	{#if push.status === 'denied'}
		<span class="state">Blocked</span>
	{:else if push.status === 'unsupported'}
		<span class="state">Not supported</span>
	{:else if push.status !== 'install'}
		<button
			class="switch"
			class:on={push.status === 'on'}
			role="switch"
			aria-checked={push.status === 'on'}
			aria-label="Notifications"
			disabled={push.busy}
			onclick={push.toggle}
		>
			<span class="knob"></span>
		</button>
	{/if}
</div>

<style>
	.nrow {
		display: flex;
		align-items: center;
		gap: 10px;
		min-height: 52px;
		margin: 0 12px 8px;
		padding: 4px 6px 4px 14px;
		border: 1px solid var(--border);
		border-radius: 12px;
	}

	.text {
		flex: 1;
		min-width: 0;
		display: flex;
		flex-direction: column;
		gap: 2px;
	}

	.label {
		font-size: 15px;
	}

	.hint,
	.state {
		font-size: 12px;
		color: var(--muted);
	}

	.state {
		flex: none;
		padding-right: 8px;
	}

	/* A 51 x 31pt track inside a 44pt-high touch area. */
	.switch {
		flex: none;
		display: flex;
		align-items: center;
		width: 63px;
		height: 44px;
		padding: 0 6px;
		background: none;
		border: 0;
		user-select: none;
		-webkit-user-select: none;
	}

	.knob {
		position: relative;
		display: block;
		width: 51px;
		height: 31px;
		border-radius: 16px;
		background: #3a3a3c;
		transition: background 0.18s var(--ease);
	}

	.knob::after {
		content: '';
		position: absolute;
		top: 2px;
		left: 2px;
		width: 27px;
		height: 27px;
		border-radius: 50%;
		background: #fff;
		transition: transform 0.18s var(--ease);
	}

	.switch.on .knob {
		background: var(--green);
	}

	.switch.on .knob::after {
		transform: translateX(20px);
	}

	.switch:disabled {
		opacity: 0.6;
	}

	@media (prefers-reduced-motion: reduce) {
		.knob,
		.knob::after {
			transition: none;
		}
	}
</style>
