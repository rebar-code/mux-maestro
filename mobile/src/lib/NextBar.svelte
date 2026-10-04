<script lang="ts">
	import { resolve } from '$app/paths';
	import type { Thread } from './types';

	/** The next thread that waits for the human. A tap opens it. */
	const { thread }: { thread: Thread } = $props();
</script>

<a class="next" href={resolve('/t/[id]', { id: thread.id })} data-next={thread.id}>
	<span class="dot waiting"></span>
	<span class="n"><small>Next</small> {thread.session} · {thread.name}</span>
	<span aria-hidden="true">›</span>
</a>

<style>
	.next {
		flex: none;
		display: flex;
		align-items: center;
		gap: 8px;
		min-height: var(--hit);
		margin: 0 max(10px, env(safe-area-inset-right)) 8px max(10px, env(safe-area-inset-left));
		padding: 10px 12px;
		border-radius: 12px;
		background: #1f1110;
		border: 1px solid #5a2320;
	}

	.next:active {
		filter: brightness(1.3);
	}

	.dot {
		margin: 0;
	}

	.n {
		flex: 1;
		min-width: 0;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	small {
		color: var(--muted);
	}
</style>
