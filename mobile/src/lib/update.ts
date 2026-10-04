import { drafts } from './drafts';

/** What a pending reload has to wait for. */
export interface ReloadState {
	/** The page is in the background. */
	hidden: boolean;
	/** A text box has the focus: the keyboard is up. */
	typing: boolean;
	/** A text box holds text that was not sent. */
	unsent: boolean;
	/** Writes in flight: a reply, a file, a manager turn. */
	holds: number;
	/** Something that must not be cut is running: a voice turn. */
	blocked: boolean;
}

/**
 * Whether the page may reload now to run a new build. It waits for a write
 * that is on its way, for a voice turn, for text that was typed and not sent,
 * and for the keyboard under the fingers.
 */
export function canReload(state: ReloadState): boolean {
	if (state.holds > 0 || state.blocked || state.unsent) return false;
	return state.hidden || !state.typing;
}

let holds = 0;

/** A write is on its way: no reload until the function returned is called. */
export function holdReload(): () => void {
	holds += 1;
	let released = false;
	return () => {
		if (released) return;
		released = true;
		holds -= 1;
	};
}

const blockers: (() => boolean)[] = [];

/**
 * No reload while `busy` says so. For work with many ways to end (a voice
 * turn: sent, stopped, failed, replaced): its own state is asked, so no exit
 * can leave the reload held.
 */
export function blockReloadWhile(busy: () => boolean): void {
	blockers.push(busy);
}

const RELOADED = 'mm.reloaded';
/** Two reloads closer than this are a loop, not two builds. */
const LOOP_MS = 10_000;
/** How often a reload that had to wait is tried again. */
const RETRY_MS = 5000;

/**
 * Attachment for the app root: run the newest build. A Home Screen app is
 * rarely closed, so nothing would otherwise ask the Mac for a new worker, and
 * a page that is open keeps the code it started with. This asks each time the
 * app comes to the front, and reloads once a new worker has taken over.
 */
export function freshBuild(): (() => void) | void {
	const workers = navigator.serviceWorker;
	if (!workers) return;
	// The first worker of a first visit takes over too: that is not a new build.
	let controlled = workers.controller !== null;
	let stale = false;

	const reload = (): void => {
		if (!stale) return;
		const typing = document.activeElement?.matches('textarea, input') ?? false;
		const unsent = [...document.querySelectorAll('textarea')].some(
			(box) => box.value.trim() !== ''
		);
		const blocked = blockers.some((busy) => busy());
		const hidden = document.visibilityState === 'hidden';
		if (!canReload({ hidden, typing, unsent, holds, blocked })) return;
		// Nothing typed is lost to the reload.
		drafts.flush();
		try {
			const last = Number(sessionStorage.getItem(RELOADED) ?? 0);
			if (Date.now() - last < LOOP_MS) return;
			sessionStorage.setItem(RELOADED, String(Date.now()));
		} catch {
			// No storage: the reload still happens once per worker change.
		}
		stale = false;
		location.reload();
	};
	const changed = (): void => {
		if (!controlled) {
			controlled = true;
			return;
		}
		stale = true;
		reload();
	};
	const front = (): void => {
		if (document.visibilityState === 'visible') {
			void workers
				.getRegistration()
				.then((registration) => registration?.update())
				.catch(() => {
					// The Mac is out of reach: the next time in front asks again.
				});
		}
		reload();
	};
	workers.addEventListener('controllerchange', changed);
	document.addEventListener('visibilitychange', front);
	document.addEventListener('focusout', reload);
	// A box that was sent or emptied no longer holds the reload.
	document.addEventListener('input', reload);
	const retry = setInterval(reload, RETRY_MS);
	return () => {
		workers.removeEventListener('controllerchange', changed);
		document.removeEventListener('visibilitychange', front);
		document.removeEventListener('focusout', reload);
		document.removeEventListener('input', reload);
		clearInterval(retry);
	};
}
