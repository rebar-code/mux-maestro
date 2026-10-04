import { Collapse } from './collapse-state.svelte';
import { live } from './live.svelte';

/** The sidebar's collapsed sessions, on this device's storage and the live list. */
export const collapse = new Collapse(
	() => localStorage,
	() => live.threads
);
