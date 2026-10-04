import type { HandleClientError } from '@sveltejs/kit';
import { observe } from '$lib/observe';
import { describeError, record } from '$lib/phonelog';

// The phone log starts here, before the app draws.
observe();

/**
 * An error SvelteKit caught itself (in a load, a render, a navigation) never
 * reaches `window.onerror`, so it is logged here.
 */
export const handleError: HandleClientError = ({ error, status }) => {
	console.error(error);
	const { msg, ...rest } = describeError(error, location.origin);
	record(status === 404 ? 'warn' : 'error', 'error', msg, { ...rest, status });
};
