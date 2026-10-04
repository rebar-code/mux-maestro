import { collapse } from '$lib/collapse.svelte';
import { live } from '$lib/live.svelte';
import type { PageLoad } from './$types';

export const load: PageLoad = ({ params }) => {
	// Opening a thread from anywhere shows its session open in the sidebar.
	collapse.open(params.id, live.threads);
	return { id: params.id };
};
