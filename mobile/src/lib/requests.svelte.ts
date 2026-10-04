import { untrack } from 'svelte';
import { SvelteSet } from 'svelte/reactivity';
import { ApiError, fetchRequests, setRequestState } from './api';
import { live, OFF_LABEL } from './live.svelte';
import { isDone, withState } from './requests';
import type { RequestList, TrackedRequest } from './types';

/** How often the list is read again while the page is on screen. */
const POLL_MS = 10_000;

/** A list the page can draw: anything else is shown as unreadable, never as empty. */
function readable(list: RequestList): RequestList {
	if (!Array.isArray(list?.requests)) throw new Error('unreadable');
	return list;
}

/** The request tracker: what the human asked agents for, and the ticks from here. */
export class Requests {
	/** `null`: nothing to show, either yet (skeleton rows) or after a failed read. */
	list = $state.raw<RequestList | null>(null);
	/** Set when the list could not be read: the server's message, or `''` when it sent none. */
	error = $state<string | null>(null);
	/** Why the last tick was not saved. */
	note = $state('');
	/** The id of the row being written. */
	busy = $state<string | null>(null);
	/** Show the done rows instead of the open ones. */
	done = $state(false);
	/** The ids of the rows whose history is open. Kept across reads and ticks. */
	readonly expanded = new SvelteSet<string>();

	private loading = false;
	/** Counts the writes, so a read that started before one does not undo it. */
	private writes = 0;

	load = async (): Promise<void> => {
		if (this.loading) return;
		this.loading = true;
		const writes = this.writes;
		try {
			const list = readable(await fetchRequests());
			if (writes !== this.writes || this.busy !== null) return;
			this.error = null;
			if (JSON.stringify(list) !== JSON.stringify(this.list)) this.list = list;
		} catch (error) {
			if (writes !== this.writes || this.busy !== null) return;
			live.fail(error);
			// Rows that may be stale are not shown as if they were current.
			this.list = null;
			this.error =
				error instanceof ApiError
					? error.status === 403 && error.code === 'disabled'
						? OFF_LABEL
						: (error.detail ?? '')
					: error instanceof Error && error.message === 'unreadable'
						? ''
						: 'No connection';
		} finally {
			this.loading = false;
		}
	};

	/** Open or close one row's history. */
	toggleHistory = (id: string): void => {
		if (!this.expanded.delete(id)) this.expanded.add(id);
	};

	/** The Retry button: skeleton rows until the answer. */
	retry = (): void => {
		this.error = null;
		void this.load();
	};

	/** Tick an open row done, or a done row back to todo. One write at a time. */
	toggle = async (request: TrackedRequest): Promise<void> => {
		if (this.busy !== null || !this.list) return;
		const before = request.state;
		const after = isDone(before) ? 'todo' : 'done';
		this.note = '';
		this.busy = request.id;
		this.writes += 1;
		// The tick shows at once; the Mac's answer replaces it.
		this.list = withState(this.list, request.id, after);
		let saved = false;
		try {
			this.list = readable(await setRequestState(request.id, after));
			this.error = null;
			saved = true;
		} catch (error) {
			live.fail(error);
			if (this.list) this.list = withState(this.list, request.id, before, after);
			this.note = error instanceof ApiError ? (error.detail ?? 'Not saved') : 'No connection';
		} finally {
			this.busy = null;
		}
		// After a failed write, read what the Mac holds now.
		if (!saved) void this.load();
	};

	/**
	 * Attachment: read the list now, again when the page comes back on screen,
	 * and every 10 s while it is on screen.
	 */
	watch = (): (() => void) =>
		untrack(() => {
			const visible = (): boolean => document.visibilityState === 'visible';
			const onVisibility = (): void => {
				if (visible()) void this.load();
			};
			void this.load();
			document.addEventListener('visibilitychange', onVisibility);
			const timer = setInterval(onVisibility, POLL_MS);
			return () => {
				document.removeEventListener('visibilitychange', onVisibility);
				clearInterval(timer);
			};
		});
}
