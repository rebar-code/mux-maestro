import { goto } from '$app/navigation';
import { resolve } from '$app/paths';
import { parseThreadLink, threadForLink } from './links';
import { live } from './live.svelte';
import { maestro } from './maestro.svelte';

/**
 * A tap on a `muxmaestro://` link in rendered markdown: the session opens
 * inside this app, the way a Go control opens it. A link whose session is not
 * in the thread list is marked, so a tap that goes nowhere shows that it did.
 */
export function openThreadLink(node: HTMLElement): void {
	const link = parseThreadLink(node.dataset.threadLink ?? '');
	const thread = link ? threadForLink(link, live.threads ?? []) : null;
	node.toggleAttribute('data-missing', thread === null);
	if (!thread) return;
	const href = resolve('/t/[id]', { id: thread.id });
	maestro.jump(href);
	void goto(href);
}
